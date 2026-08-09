import Foundation

/// Antigravity 额度抓取器
///
/// 不直接读取 Google OAuth access token：
/// - 本地 `state.vscdb` 里的 token 可能已经过期，直接请求 cloudcode 会 401
/// - Antigravity 实际可用的认证链在它自己的本地 language_server 内
///
/// 自动发现本机 Antigravity 后端（IDE 或 agy CLI），复用它们的本地 RPC：
///
/// 1. 用 `pgrep` 扫描所有 `language_server` 进程 + `agy` / `antigravity-cli` 进程
/// 2. 根据命令行分类：
///    - **IDE**：`language_server` 二进制 + 命令行含 `antigravity` 字样 + 需要 `--csrf_token`
///    - **CLI**：`agy` / `antigravity-cli` 二进制（路径锚定，避免 `stragy` 误匹配），无 CSRF
/// 3. 用 `lsof` 找到该进程监听的 HTTPS 端口
/// 4. 调本地受保护接口：
///    - `GetUserStatus` — 拿账号邮箱 + 套餐名（userTier.name / planStatus.planInfo）
///    - `GetLoadCodeAssist` — 套餐名 fallback（部分旧版本不返回 userTier）
///    - `RetrieveUserQuotaSummary` — 5h / 周额度
struct AntigravityFetcher: QuotaFetcher {
    let providerID = "antigravity"
    let displayName = "Antigravity"
    let kind: ProviderKind = .antigravity

    private let session: URLSession
    private let metadataServerDiscovery: @Sendable () -> [ServerInfo]

    init(
        metadataServerDiscovery: @escaping @Sendable () -> [ServerInfo] = {
            AntigravityFetcher.defaultMetadataServers()
        }
    ) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = HTTPTimeouts.antigravityRequest
        config.timeoutIntervalForResource = HTTPTimeouts.antigravityResource
        self.session = URLSession(
            configuration: config,
            delegate: LocalhostTrustDelegate(),
            delegateQueue: nil
        )
        self.metadataServerDiscovery = metadataServerDiscovery
    }

    func hasLocalAuth() -> Bool {
        // 真正的探测需要 pgrep/lsof；这个方法会在菜单和配置变更的主线程路径中
        // 频繁调用，这里返回 true 表示"潜在可用"，把进程发现推迟到 async fetch()，
        // 避免打开菜单或设置窗口时发生可感知卡顿。
        true
    }

    func checkLocalAuth() async -> Bool {
        (try? await Self.discoverServerAsync()) != nil
    }

    func fetch(mode: RefreshMode) async throws -> QuotaInfo {
        let server = try await Self.discoverServerAsync()

        async let userStatus: UserStatusEnvelope? = postOptional(
            server: server,
            path: "/exa.language_server_pb.LanguageServerService/GetUserStatus",
            body: UserStatusRequest(metadata: .init(
                ideName: "antigravity",
                extensionName: "antigravity",
                ideVersion: "unknown",
                locale: "en"
            ))
        )
        async let loadCodeAssist: LoadCodeAssistEnvelope? = postOptional(
            server: server,
            path: "/exa.language_server_pb.LanguageServerService/GetLoadCodeAssist"
        )
        async let quotaSummary: RetrieveUserQuotaSummaryEnvelope = post(
            server: server,
            path: "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary"
        )

        let user = await userStatus
        let load = await loadCodeAssist
        let quota = try await quotaSummary

        let account = Self.parseAccount(
            userStatus: user?.userStatus,
            fallbackTier: load?.response.currentTier?.name
        )
        let models = try Self.makeModels(from: quota.response)
        return QuotaInfo(
            models: models,
            resetCredits: nil,
            planLabel: account.planLabel,
            accountEmail: account.accountEmail,
            codexUsageDetails: nil,
            fetchedAt: Date()
        )
    }

    // MARK: - Public RPC helpers (reused by AntigravityLocalUsageScanner)

    /// 单次 LLM 调用的 token 用量（来自 `GetCascadeTrajectoryGeneratorMetadata`）
    struct UsageEvent: Equatable, Codable, Sendable {
        let timestamp: Date?
        let model: String?
        let inputTokens: Int
        let outputTokens: Int
        let cacheReadTokens: Int
        let cacheWriteTokens: Int
        let reasoningTokens: Int
        let totalTokens: Int
        let stepIndices: [Int]?

        init(
            timestamp: Date?,
            model: String?,
            inputTokens: Int,
            outputTokens: Int,
            cacheReadTokens: Int,
            cacheWriteTokens: Int,
            reasoningTokens: Int,
            totalTokens: Int,
            stepIndices: [Int]? = nil
        ) {
            self.timestamp = timestamp
            self.model = model
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.cacheReadTokens = cacheReadTokens
            self.cacheWriteTokens = cacheWriteTokens
            self.reasoningTokens = reasoningTokens
            self.totalTokens = totalTokens
            self.stepIndices = stepIndices
        }
    }

    /// 单个 trajectory / session 的 generatorMetadata 列表。
    /// 失败/没有数据 → 返回空数组（不抛错，让 scanner 决定怎么标记 failed）。
    func getTrajectoryMetadata(sessionId: String) async throws -> [UsageEvent] {
        let servers = discoverMetadataServers()
        return try await getTrajectoryMetadata(sessionId: sessionId, servers: servers)
    }

    func discoverMetadataServers() -> [ServerInfo] {
        metadataServerDiscovery()
    }

    /// 使用一次扫描开始时已经发现的服务器查询 session。
    ///
    /// Scanner 会把同一份 `servers` 复用于所有 dirty sessions，避免每个 session
    /// 都重新执行三次 pgrep + 多次 lsof。公开发现仍保留在上面的便利入口，供单次
    /// 调用和兼容旧调用方使用。
    func getTrajectoryMetadata(
        sessionId: String,
        servers: [ServerInfo]
    ) async throws -> [UsageEvent] {
        guard !servers.isEmpty else {
            throw QuotaError.networkError("未发现 Antigravity IDE 或 agy CLI 进程，请先启动 Antigravity 并完成登录")
        }

        struct Request: Encodable {
            let cascadeId: String
        }
        struct Envelope: Decodable {
            let generatorMetadata: [AnyJSON]?
        }

        var hadSuccessfulResponse = false
        var lastError: Error?
        for server in servers {
            do {
                let envelope: Envelope = try await post(
                    server: server,
                    path: "/exa.language_server_pb.LanguageServerService/GetCascadeTrajectoryGeneratorMetadata",
                    body: Request(cascadeId: sessionId)
                )
                hadSuccessfulResponse = true
                guard let rawEvents = envelope.generatorMetadata, !rawEvents.isEmpty else {
                    continue
                }
                let events = rawEvents.compactMap { Self.parseUsageEvent(from: $0) }
                if !events.isEmpty {
                    logInfo("[antigravity] session=\(sessionId) 成功从 pid=\(server.pid) port=\(server.httpsPort) 获取到 \(events.count) 个 events")
                    return events
                }
            } catch {
                lastError = error
                logInfo("[antigravity] session=\(sessionId) pid=\(server.pid) 查询失败，尝试下一个 server: \(error.localizedDescription)")
            }
        }
        if !hadSuccessfulResponse {
            throw lastError ?? QuotaError.invalidResponse
        }
        return []
    }

    /// 递归遍历 JSON，按 key 名正则把 token 计数归类到 `UsageEvent`。
    /// - timestamp：任意嵌套层都接受，但只匹配明确的 timestamp/created/time
    ///   白名单。候选按 key 语义、嵌套深度和日期排序，结果不受 JSON 字段遍历顺序
    ///   影响；duration / latency / time_to_first_token 等耗时字段不会参与匹配。
    ///   `parseTimestamp` 同时限制日期必须落在合理的现代 epoch 范围内。
    /// - model：只在顶层取，避免把嵌套层的 model 列表（数组）当主 model。
    /// - token 数字：每一类取递归遍历中出现的最大值，而不是把不同嵌套层相加。
    ///   RPC 的若干版本会在 wrapper 和 usage 对象中重复携带同一份计数；累加会
    ///   双重计数。单个 generatorMetadata entry 代表一次调用，因此每类的最大
    ///   非负计数是更稳妥的兼容策略。
    private nonisolated static func parseUsageEvent(from json: AnyJSON) -> UsageEvent? {
        var inputTokens = 0
        var outputTokens = 0
        var cacheReadTokens = 0
        var cacheWriteTokens = 0
        var reasoningTokens = 0
        var totalTokens = 0
        var extractedStepIndices: [Int]? = nil
        var timestampCandidates: [(priority: Int, depth: Int, date: Date)] = []
        var modelCandidates: [(priority: Int, depth: Int, value: String)] = []

        func visit(_ value: AnyJSON, depth: Int) {
            guard depth < 32 else { return }
            switch value {
            case .object(let dict):
                for (key, child) in dict {
                    let lower = key.lowercased()
                    if lower == "stepindices" || lower == "step_indices" {
                        if case .array(let arr) = child {
                            let nums = arr.compactMap(\.intValue)
                            if !nums.isEmpty {
                                extractedStepIndices = nums
                            }
                        }
                    }
                    if lower == "apiprovider" || lower == "api_provider" {
                        if let str = child.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !str.isEmpty {
                            modelCandidates.append((priority: 4, depth: depth, value: str))
                        }
                    }
                    if let priority = Self.timestampPriority(forKey: lower),
                       let parsed = Self.parseTimestamp(child) {
                        timestampCandidates.append((priority, depth, parsed))
                    }
                    // generator metadata 的真实响应会把 model 放在
                    // metadata.chatModel.model 等嵌套层级。旧逻辑只读顶层，
                    // 导致所有 Antigravity 样本都无法区分 Gemini / Claude。
                    if let priority = Self.modelPriority(forKey: lower),
                       let str = child.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !str.isEmpty,
                       !str.hasPrefix("MODEL_PLACEHOLDER_") {
                        modelCandidates.append((priority, depth, str))
                    }
                    if let n = child.intValue, n >= 0 {
                        if Self.matches(lower, pattern: #"^(input|prompt).*token"#) {
                            inputTokens = max(inputTokens, n)
                        } else if Self.matches(lower, pattern: #"^(output|completion).*token"#) {
                            outputTokens = max(outputTokens, n)
                        } else if Self.matches(lower, pattern: #"cache.*read.*token"#) {
                            cacheReadTokens = max(cacheReadTokens, n)
                        } else if Self.matches(lower, pattern: #"cache.*write.*token"#) {
                            cacheWriteTokens = max(cacheWriteTokens, n)
                        } else if Self.matches(lower, pattern: #"(reasoning|thinking).*token"#) {
                            reasoningTokens = max(reasoningTokens, n)
                        } else if lower == "totaltokens" || lower == "total_tokens" {
                            totalTokens = max(totalTokens, n)
                        }
                    }
                    visit(child, depth: depth + 1)
                }
            case .array(let arr):
                for child in arr {
                    visit(child, depth: depth + 1)
                }
            case .null, .string, .bool, .number:
                break
            }
        }

        visit(json, depth: 0)
        let timestamp = timestampCandidates.min { lhs, rhs in
            if lhs.priority != rhs.priority {
                return lhs.priority < rhs.priority
            }
            if lhs.depth != rhs.depth {
                return lhs.depth < rhs.depth
            }
            return lhs.date < rhs.date
        }?.date
        let model = modelCandidates.min { lhs, rhs in
            if lhs.priority != rhs.priority {
                return lhs.priority < rhs.priority
            }
            if lhs.depth != rhs.depth {
                return lhs.depth < rhs.depth
            }
            return lhs.value < rhs.value
        }?.value

        // cacheWrite 是缓存簿记量，不计入对外 token 总量。部分 RPC 版本的
        // totalTokens 会把 cacheWrite 算进去，所以不能直接信任 server total；
        // 以各分量按约定计算，只有分量完全缺失时才采用 server total。
        let components = [inputTokens, outputTokens, cacheReadTokens, reasoningTokens]
        let computedTotal = components.reduce(0, Self.saturatingAdd)
        let finalTotal = computedTotal > 0 ? computedTotal : totalTokens

        // 完全没有 token 数据的事件跳过（避免空 entry 污染聚合）
        guard finalTotal > 0 || cacheWriteTokens > 0 else {
            return nil
        }
        return UsageEvent(
            timestamp: timestamp,
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens,
            reasoningTokens: reasoningTokens,
            totalTokens: finalTotal,
            stepIndices: extractedStepIndices
        )
    }

    /// 明确模型字段优先于包含 "model" 的兼容字段；深度只作为同优先级的
    /// 次级排序，因此 `metadata.chatModel.model` 可以稳定覆盖外围描述字段。
    private nonisolated static func modelPriority(forKey key: String) -> Int? {
        switch key {
        case "model":
            return 0
        case "response_model", "responsemodel":
            return 1
        case "model_name", "modelname":
            return 2
        default:
            return key.contains("model") ? 3 : nil
        }
    }

    /// 明确的事件时间字段白名单。数字越小优先级越高：
    /// - timestamp 是 RPC 已知主字段；
    /// - createdAt / created 是兼容旧响应的 fallback；
    /// - time 只保留历史兼容，不能盖过语义更明确的字段。
    ///
    /// 先移除常见分隔符以同时支持 camelCase / snake_case / kebab-case，但最终仍
    /// 只做完整字符串匹配，`generation_time_ms`、`time_to_first_token` 等不会命中。
    private nonisolated static func timestampPriority(forKey key: String) -> Int? {
        let normalized = key.filter(\.isLetter).lowercased()
        switch normalized {
        case "timestamp", "timestampms", "timestampseconds":
            return 0
        case "eventtimestamp":
            return 1
        case "createdat":
            return 2
        case "created":
            return 3
        case "time":
            return 4
        default:
            return nil
        }
    }

    private nonisolated static func parseTimestamp(_ value: AnyJSON) -> Date? {
        // Antigravity 是现代产品；2000...2100 足以覆盖真实会话，同时排除 duration、
        // 相对计时器和单位误判造成的 1970 / 极远未来日期。
        let minimumEpochSeconds = 946_684_800.0   // 2000-01-01T00:00:00Z
        let maximumEpochSeconds = 4_102_444_800.0 // 2100-01-01T00:00:00Z

        func isReasonable(_ date: Date) -> Bool {
            let seconds = date.timeIntervalSince1970
            return seconds >= minimumEpochSeconds && seconds < maximumEpochSeconds
        }

        if let n = value.doubleValue, n.isFinite {
            // epoch seconds 跟 millis 都吃：> 20 000 000 000 视为 millis
            let seconds = n > 20_000_000_000 ? n / 1000 : n
            let date = Date(timeIntervalSince1970: seconds)
            return isReasonable(date) ? date : nil
        }
        if let s = value.stringValue, !s.isEmpty {
            guard let date = DateParser.parse(s), isReasonable(date) else {
                return nil
            }
            return date
        }
        return nil
    }

    private nonisolated static func matches(_ text: String, pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    private nonisolated static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : sum
    }

    // MARK: - Local RPC

    private func post<Response: Decodable>(
        server: ServerInfo,
        path: String,
        body: Encodable? = nil
    ) async throws -> Response {
        let (data, response) = try await rawPost(server: server, path: path, body: body)
        try Self.checkHTTP(response: response, data: data)

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

    private func postOptional<Response: Decodable>(
        server: ServerInfo,
        path: String,
        body: Encodable? = nil
    ) async -> Response? {
        do {
            let (data, response) = try await rawPost(server: server, path: path, body: body)
            try Self.checkHTTP(response: response, data: data)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(Response.self, from: data)
        } catch {
            logWarn("[antigravity] 可选接口 \(path) 失败，将使用兜底: \(error.localizedDescription)")
            return nil
        }
    }

    private func rawPost(
        server: ServerInfo,
        path: String,
        body: Encodable?
    ) async throws -> (Data, URLResponse) {
        try Task.checkCancellation()
        guard Self.serverStillOwnsEndpoint(server) else {
            throw QuotaError.networkError(
                "Antigravity 本地服务身份已变化（pid=\(server.pid), port=\(server.httpsPort)），请重试刷新"
            )
        }
        guard let url = URL(string: "https://127.0.0.1:\(server.httpsPort)\(path)") else {
            throw QuotaError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if let body {
            let encoder = JSONEncoder()
            request.httpBody = try encoder.encode(body)
        } else {
            request.httpBody = Data("{}".utf8)
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let csrfToken = server.csrfToken, !csrfToken.isEmpty {
            request.setValue(csrfToken, forHTTPHeaderField: "x-codeium-csrf-token")
        }

        logInfo("[antigravity] POST \(url.absoluteString) (kind=\(server.kind.rawValue))")
        let startedAt = Date()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            // 保留取消错误类型，让 AppState/CancellationFilter 走 deferred 路径。
            throw error
        } catch let error as URLError {
            throw QuotaError.networkError(
                "Antigravity RPC 失败: \(HTTPRequestLogSanitizer.networkErrorDescription(error))"
            )
        }
        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let bodyBytes = data.count
        logInfo("[antigravity] ← \(status) \(bodyBytes) bytes in \(elapsedMs)ms \(url.lastPathComponent)")
        return (data, response)
    }

    private nonisolated static func checkHTTP(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw QuotaError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw QuotaError.httpError(
                status: http.statusCode,
                body: "响应 \(data.count) bytes"
            )
        }
    }

    // MARK: - Mapping

    /// 账号信息：(planLabel, accountEmail)。任一为 nil 表示该字段无法确定。
    struct AccountInfo {
        let planLabel: String?
        let accountEmail: String?
    }

    /// 解析账号信息：邮箱取 `userStatus.email`；套餐名优先级
    /// `userStatus.userTier.name` > `userStatus.planStatus.planInfo.*` > `GetLoadCodeAssist.currentTier.name`。
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


    private nonisolated static func makeModels(from response: RetrieveUserQuotaSummaryResponse) throws -> [ModelQuota] {
        let models = try response.groups.compactMap { group -> ModelQuota? in
            let weekly = bucket(for: "weekly", in: group.buckets)
            let fiveHour = bucket(for: "5h", in: group.buckets)

            guard weekly != nil || fiveHour != nil else { return nil }

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

            return ModelQuota(
                modelName: normalizedModelName(from: group),
                intervalTotalCount: 0,
                intervalUsageCount: 0,
                intervalRemainingPercent: fiveHourPercent,
                intervalStatus: fiveHour == nil ? .absent : .present,
                intervalResetsAt: fiveHour?.resetTime,
                intervalWindowSeconds: nil,
                weeklyTotalCount: 0,
                weeklyUsageCount: 0,
                weeklyRemainingPercent: weeklyPercent,
                weeklyStatus: weekly == nil ? .absent : .present,
                weeklyResetsAt: weekly?.resetTime,
                weeklyWindowSeconds: nil
            )
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
        case AntigravityModelKind.claudeAndGptModels.rawValue: return 1
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
    /// 从 raw JSON Data 解析账号信息（仅用于单元测试）。
    /// 让测试不需要直接构造 `UserStatus` 等内部类型。
    nonisolated static func parseAccountFromJSON(_ data: Data, fallbackTier: String?) -> AccountInfo? {
        let decoder = JSONDecoder()
        guard let envelope = try? decoder.decode(UserStatusEnvelope.self, from: data) else { return nil }
        return parseAccount(userStatus: envelope.userStatus, fallbackTier: fallbackTier)
    }

    /// 从 `AnyJSON` 直接调用 `parseUsageEvent`（仅测试用，跳过 Data → JSON 解析层）
    nonisolated static func parseUsageEventForTest(_ json: AnyJSON) -> UsageEvent? {
        parseUsageEvent(from: json)
    }

    /// 从 quota response JSON 构造模型（仅用于验证 bucket presence/status 契约）。
    nonisolated static func parseQuotaModelsForTest(_ data: Data) throws -> [ModelQuota] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try makeModels(from: decoder.decode(RetrieveUserQuotaSummaryResponse.self, from: data))
    }
}
