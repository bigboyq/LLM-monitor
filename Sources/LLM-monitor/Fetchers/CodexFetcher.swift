import Foundation

/// OpenAI Codex / ChatGPT Plan 额度抓取器
///
/// 与 Codex CLI 的本地 session JSONL 统计语义保持一致：
///   1. 从 ~/.codex/auth.json 读 access_token + account_id
///   2. 调 https://chatgpt.com/backend-api/wham/usage 拿实时 rate_limit
///      （primary_window，部分旧 schema 还会返回 secondary_window）
///   3. 调 https://chatgpt.com/backend-api/wham/rate-limit-reset-credits 拿 reset credits 数量
///
/// 响应里给的是 used_percent（已用百分比），映射成 QuotaInfo 的 remainingPercent (100 - used)。
struct CodexFetcher: QuotaFetcher {
    /// Reset credits 实际数量很小；限制响应及 fallback 合成条目数，避免异常远端
    /// `available_count` 或超大数组造成无界内存/CPU 消耗。
    private static let maxResetCreditEntries = 1_000
    /// ChatGPT/Codex 的真实额度窗口远短于一年。统一限制秒/分钟两种 schema
    /// 转换后的窗口长度，避免异常远端值制造极端 Date 区间或整数转换 trap。
    private static let maxUsageWindowSeconds = 366 * 24 * 60 * 60

    let providerID = "codex_chatgpt"
    let displayName = "ChatGPT Plan"
    let kind: ProviderKind = .codexChatGpt
    /// reset credits + usage details 不是每次主 quota 刷新都会带回来；
    /// 缺失时回退到上次的值，避免 UI 看到空白。
    let resultMerger: RefreshResultMerger = CodexFillingMissingMerger()

    /// auth.json 文件路径（默认 ~/.codex/auth.json），可被环境变量 CODEX_HOME 或 config.json 的 authPath 覆盖
    let authFileURL: URL

    private let usageURL: URL
    private let resetCreditsURL: URL
    private let usageClient: HTTPClient
    private let resetCreditsClient: HTTPClient

    /// 从 config.json 传入的 authPath（可选，~ 开头会展开）
    init(authPath: String? = nil,
         usageURL: URL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
         resetCreditsURL: URL = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!,
         session: URLSession = .shared) {
        let resolvedAuthURL: URL
        if let path = authPath, !path.isEmpty {
            resolvedAuthURL = Self.resolveAuthFileURL(from: URL(fileURLWithPath: NSString(string: path).expandingTildeInPath))
        } else {
            resolvedAuthURL = Self.defaultAuthFileURL()
        }
        self.authFileURL = resolvedAuthURL
        self.usageURL = usageURL
        self.resetCreditsURL = resetCreditsURL
        // session 不再存为 stored property——HTTPClient 持 URLSession，不需要在 fetcher
        // 里保留 reference。init 参数保留是为了方便测试时注入 mock URLSession。
        self.usageClient = HTTPClient(session: session, logTag: "[codex/usage]", defaultTimeout: HTTPTimeouts.codex)
        self.resetCreditsClient = HTTPClient(session: session, logTag: "[codex/reset-credits]", defaultTimeout: HTTPTimeouts.codex)
    }

    nonisolated static func defaultAuthFileURL() -> URL {
        if let env = ProcessInfo.processInfo.environment["CODEX_HOME"], !env.isEmpty {
            return resolveAuthFileURL(from: URL(fileURLWithPath: env))
        }
        return URL(fileURLWithPath: NSString("~/.codex/auth.json").expandingTildeInPath)
    }

    /// R14: auth.json 读取的硬上限。
    static let maxAuthFileBytes: Int = 1 * 1024 * 1024  // 1 MiB

    /// R14: 认证文件超过 1 MiB 的稳定错误标记。
    struct CodexAuthFileTooLargeError: Error {}

    /// 用 FileHandle 分块读取并施加硬上限。超限抛 `CodexAuthFileTooLargeError`；
    /// 不做读取前 stat（stat 仍可能被 TOCTOU 绕过），改为读取过程中累计字节。
    /// 按已锁定本地威胁模型不拒绝 symlink，但解析目标内容仍受大小限制。
    /// 不把路径或文件内容写日志。
    nonisolated static func readBounded(_ url: URL, maxBytes: Int) throws -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw NSError(domain: "codex-auth-read", code: 1)
        }
        defer { try? handle.close() }
        var data = Data()
        let chunkSize = 64 * 1024
        while true {
            if Task.isCancelled { throw CancellationError() }
            guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            data.append(chunk)
            if data.count > maxBytes {
                throw CodexAuthFileTooLargeError()
            }
        }
        return data
    }

    nonisolated static func resolveAuthFileURL(from pathURL: URL) -> URL {
        if pathURL.hasDirectoryPath || pathURL.pathExtension.isEmpty {
            return pathURL.appendingPathComponent("auth.json")
        }
        return pathURL
    }

    // MARK: - QuotaFetcher

    func hasLocalAuth() -> Bool {
        FileManager.default.fileExists(atPath: authFileURL.path)
    }

    func fetch(mode: RefreshMode) async throws -> QuotaInfo {
        let auth = try loadAuth()
        let headers = try Self.authHeaders(from: auth)

        // 1. 拿实时 rate_limit
        let usage = try await fetchUsage(headers: headers)
        let model = try Self.parseUsage(usage)

        // 2. 拿 reset credits 详情（失败不阻塞主流程，但 warn 出来）
        // R3: reset credits 有独立新鲜度。full 成功时记录实际抓取时间、清失败标志；
        // full 失败或 background 跳过时这里返回 nil，由 CodexFillingMissingMerger 根据
        // mode 区分"失败（标记过期）"与"按设计跳过（保持原样新鲜度）"。
        var resetCredits: ResetCreditsInfo? = nil
        if mode == .full {
            do {
                let reset = try await fetchResetCredits(headers: headers)
                resetCredits = reset.toInfo(fetchedAt: Date())
                logInfo("[codex] reset credits: 可用 \(resetCredits?.availableCount ?? 0) / 共 \(resetCredits?.entries.count ?? 0) 条")
            } catch {
                logWarn("[codex] reset-credits 拉取失败: \(error.localizedDescription)，忽略")
            }
        } else {
            logDebug("[codex] background refresh: 跳过 reset credits 请求")
        }

        return QuotaInfo(
            models: [model],
            resetCredits: resetCredits,
            planLabel: Self.planLabel(from: auth),
            accountEmail: auth.accountEmail,
            codexUsageDetails: nil,
            fetchedAt: Date()
        )
    }

    nonisolated static func loadUsageDetailsAsync(authPath: String?, model: ModelQuota) async -> CodexUsageDetails? {
        let authURL: URL
        if let authPath, !authPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            authURL = resolveAuthFileURL(from: URL(fileURLWithPath: NSString(string: authPath).expandingTildeInPath))
        } else {
            authURL = defaultAuthFileURL()
        }

        let codexHome = authURL.deletingLastPathComponent()
        guard !Task.isCancelled else { return nil }

        let windows = makeUsageWindows(from: model)
        if windows.isEmpty {
            logDebug("[codex/local] 无可用 usage window，跳过本地明细扫描")
        } else {
            let briefDescriptions = windows
                .map { key, window in
                    "\(key): \(safeWindowDurationDescription(window))"
                }
                .sorted()
                .joined(separator: ", ")
            logInfo("[codex/local] usage windows = \(briefDescriptions)")
            // 描述构造放进 logDebug 的 @autoclosure，Release 不会创建 formatter
            // 或拼接字符串。
            logDebug("[codex/local] usage window ranges (UTC): \(debugUsageWindowDescriptions(windows))")
        }

        guard !windows.isEmpty, !Task.isCancelled else { return nil }
        let dailyWindows = recentDailyUsageWindows()
        logDebug("[codex/local] daily window ranges (UTC): \(debugDailyWindowDescriptions(dailyWindows))")
        let earliestWindowStart = (windows.values.map(\.startDate) + dailyWindows.map(\.startDate)).min()
        let candidateFiles = sessionFiles(codexHome: codexHome, modifiedSince: earliestWindowStart)
        let windowFingerprint = localUsageWindowFingerprint(windows, dailyWindows: dailyWindows)
        let sourceFingerprint = localUsageSourceFingerprint(candidateFiles)

        if let cached = await CodexUsageDetailsCache.shared.value(
            for: codexHome,
            windowFingerprint: windowFingerprint,
            sourceFingerprint: sourceFingerprint
        ) {
            logInfo("[codex/local] 使用缓存：session files=\(candidateFiles.count)")
            return cached
        }

        guard !Task.isCancelled else { return nil }
        let sessionFiles = await cachedSessionEvents(for: candidateFiles)
        guard !Task.isCancelled else { return nil }
        let summaries = summarizeLocalUsage(
            windows: windows,
            dailyWindows: dailyWindows,
            sessionFiles: sessionFiles
        )
        guard !Task.isCancelled else { return nil }
        let lastPrompt = latestPromptUsage(
            sessionFiles: sessionFiles,
            fileURL: summaries.latestPromptFile,
            turnID: summaries.latestPromptTurnID,
            completedAt: summaries.latestPromptCompletedAt
        )
        guard !Task.isCancelled else { return nil }

        let details = CodexUsageDetails(
            primary: summaries.usageSummaries["primary"],
            secondary: summaries.usageSummaries["secondary"],
            lastPrompt: lastPrompt,
            dailyTokenUsage: summaries.dailyTokenUsage,
            scannedAt: Date()
        )
        await CodexUsageDetailsCache.shared.store(
            details,
            for: codexHome,
            windowFingerprint: windowFingerprint,
            sourceFingerprint: sourceFingerprint
        )
        return details
    }

    // MARK: - auth.json

    private struct AuthFile {
        let accessToken: String
        let accountId: String?
        let planType: String?
        let accountEmail: String?
    }

    private func loadAuth() throws -> AuthFile {
        let data: Data
        do {
            // R14: 用 FileHandle 分块读取并施加 1 MiB 硬上限，不能只做读取前 stat；
            // 超限返回稳定错误，不把路径/内容写日志。
            data = try Self.readBounded(authFileURL, maxBytes: Self.maxAuthFileBytes)
        } catch is CodexAuthFileTooLargeError {
            throw QuotaError.networkError("Codex 认证文件过大")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // 不附带完整路径或底层错误描述；二者都可能泄露用户名和自定义目录。
            throw QuotaError.networkError(
                "无法读取 Codex 认证文件（\(authFileURL.lastPathComponent)）"
            )
        }

        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw QuotaError.decodingError("auth.json 不是合法 JSON")
        }
        guard let dict = json as? [String: Any] else {
            throw QuotaError.decodingError("auth.json 顶层不是对象")
        }
        guard let tokens = dict["tokens"] as? [String: Any] else {
            throw QuotaError.decodingError("auth.json 缺 tokens")
        }
        guard let accessToken = tokens["access_token"] as? String, !accessToken.isEmpty else {
            throw QuotaError.missingAPIKey
        }
        let accountId = tokens["account_id"] as? String

        var planType: String?
        var accountEmail: String?

        if let emailInDict = dict["email"] as? String ?? (tokens["email"] as? String), !emailInDict.isEmpty {
            accountEmail = emailInDict
        }

        // plan type 和 email 进一步尝试从 id_token 的 payload 里解
        if let idToken = tokens["id_token"] as? String {
            let jwtInfo = Self.parseJWT(idToken)
            if planType == nil { planType = jwtInfo.planType }
            if accountEmail == nil { accountEmail = jwtInfo.email }
        }

        return AuthFile(
            accessToken: accessToken,
            accountId: accountId,
            planType: planType,
            accountEmail: accountEmail
        )
    }

    private nonisolated static func authHeaders(from auth: AuthFile) throws -> [String: String] {
        var headers: [String: String] = [
            "Authorization": "Bearer \(auth.accessToken)",
            "OpenAI-Beta": "codex-1",
            "originator": "Codex Desktop",
        ]
        if let accountId = auth.accountId, !accountId.isEmpty {
            headers["ChatGPT-Account-ID"] = accountId
        }
        return headers
    }

    struct JWTPayloadInfo {
        let planType: String?
        let email: String?
    }

    private nonisolated static func parseJWT(_ jwt: String) -> JWTPayloadInfo {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return JWTPayloadInfo(planType: nil, email: nil) }
        var payload = String(parts[1])
        // base64url → base64
        payload = payload.replacingOccurrences(of: "-", with: "+")
                         .replacingOccurrences(of: "_", with: "/")
        // pad
        while payload.count % 4 != 0 { payload.append("=") }
        guard let data = Data(base64Encoded: payload),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return JWTPayloadInfo(planType: nil, email: nil)
        }
        var plan: String?
        if let auth = obj["https://api.openai.com/auth"] as? [String: Any],
           let planType = auth["chatgpt_plan_type"] as? String {
            plan = planType
        }
        var email: String?
        if let emailStr = obj["email"] as? String, !emailStr.isEmpty {
            email = emailStr
        } else if let profile = obj["https://api.openai.com/profile"] as? [String: Any],
                  let profileEmail = profile["email"] as? String, !profileEmail.isEmpty {
            email = profileEmail
        }
        return JWTPayloadInfo(planType: plan, email: email)
    }

    private nonisolated static func planTypeFromJWT(_ jwt: String) -> String? {
        parseJWT(jwt).planType
    }

    private nonisolated static func planLabel(from auth: AuthFile) -> String? {
        guard let plan = auth.planType, !plan.isEmpty else { return nil }
        return plan.capitalized   // "team" → "Team"
    }

    // MARK: - API calls

    struct UsageResponse {
        let primary: Window?
        let secondary: Window?

        struct Window {
            let usedPercent: Double
            let resetsAt: Date?
            let limitWindowSeconds: Int?
        }
    }

    struct ResetCreditsResponse {
        let entries: [ResetCreditEntry]
        let serverAvailableCount: Int?
        let totalEarnedCount: Int?

        func toInfo(fetchedAt: Date) -> ResetCreditsInfo {
            ResetCreditsInfo(
                entries: entries,
                serverAvailableCount: serverAvailableCount,
                totalEarnedCount: totalEarnedCount,
                fetchedAt: fetchedAt,
                lastAttemptFailed: false
            )
        }
    }

    private func fetchUsage(headers: [String: String]) async throws -> UsageResponse {
        var req = URLRequest(url: usageURL)
        req.httpMethod = "GET"
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }

        // includeBodyInError=false：usage 响应可能含账号/诊断信息，错误日志只贴摘要
        let (data, _) = try await usageClient.send(req, includeBodyInError: false)
        return try Self.parseUsageData(data)
    }

    private func fetchResetCredits(headers: [String: String]) async throws -> ResetCreditsResponse {
        var req = URLRequest(url: resetCreditsURL)
        req.httpMethod = "GET"
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }

        // includeBodyInError=false：reset-credits 响应里含 credits 列表，错误日志只贴摘要
        let (data, _) = try await resetCreditsClient.send(req, includeBodyInError: false)
        return try Self.parseResetCreditsData(data)
    }

    // MARK: - parsing

    nonisolated static func parseUsageData(_ data: Data) throws -> UsageResponse {
        let json: Any
        do { json = try JSONSerialization.jsonObject(with: data) }
        catch { throw QuotaError.decodingError("usage 不是合法 JSON") }

        guard let dict = json as? [String: Any] else {
            throw QuotaError.decodingError("usage 顶层不是对象")
        }
        guard let rateLimit = dict["rate_limit"] as? [String: Any] else {
            logWarn("[codex] usage 响应无 rate_limit（可能账号不在 ChatGPT Plan 中）")
            throw QuotaError.decodingError("usage 响应缺少 rate_limit")
        }
        let primary = parseWindow(rateLimit["primary_window"])
        let secondary = parseWindow(rateLimit["secondary_window"])
        guard primary != nil else {
            throw QuotaError.decodingError("usage.rate_limit 缺少合法 primary_window")
        }
        logInfo("[codex] 解析：primary used=\(primary?.usedPercent ?? -1)%, window=\(primary?.limitWindowSeconds ?? 0)s；secondary used=\(secondary?.usedPercent ?? -1)%, window=\(secondary?.limitWindowSeconds ?? 0)s")
        return UsageResponse(primary: primary, secondary: secondary)
    }

    private nonisolated static func parseWindow(_ raw: Any?) -> UsageResponse.Window? {
        guard let dict = raw as? [String: Any] else { return nil }
        // used_percent 是数字（int 或 float）
        guard let usedNumber = strictJSONNumber(dict["used_percent"]) else { return nil }
        let used = usedNumber.doubleValue
        guard used.isFinite, (0...100).contains(used) else { return nil }

        let limitWindowSeconds: Int?
        if let rawSeconds = dict["limit_window_seconds"] {
            guard let seconds = positiveInt(rawSeconds),
                  seconds <= Self.maxUsageWindowSeconds else {
                return nil
            }
            limitWindowSeconds = seconds
        } else if let rawMinutes = dict["window_minutes"] {
            guard let minutes = positiveInt(rawMinutes) else { return nil }
            let (seconds, overflow) = minutes.multipliedReportingOverflow(by: 60)
            guard !overflow, seconds <= Self.maxUsageWindowSeconds else { return nil }
            limitWindowSeconds = seconds
        } else {
            limitWindowSeconds = nil
        }

        // reset_at 通过 `DateParser.parse` 统一解析：ISO8601 (带/不带小数秒)
        // 或数字（自动按 > 1e12 阈值判断秒/毫秒）。
        let resetsAt = DateParser.parse(dict["reset_at"])
        return UsageResponse.Window(
            usedPercent: used,
            resetsAt: resetsAt,
            limitWindowSeconds: limitWindowSeconds
        )
    }

    nonisolated static func parseUsage(_ usage: UsageResponse) throws -> ModelQuota {
        guard let primary = usage.primary else {
            throw QuotaError.decodingError("usage 缺少 primary_window")
        }
        let intervalUsed = primary.usedPercent
        let weeklyUsed = usage.secondary?.usedPercent ?? 0
        return ModelQuota(
            modelName: "chatgpt_plan",
            intervalTotalCount: 0,
            intervalUsageCount: 0,
            intervalRemainingPercent: max(0, min(100, 100 - intervalUsed)),
            intervalStatus: .present,
            intervalResetsAt: primary.resetsAt,
            intervalWindowSeconds: primary.limitWindowSeconds,
            weeklyTotalCount: 0,
            weeklyUsageCount: 0,
            weeklyRemainingPercent: max(0, min(100, 100 - weeklyUsed)),
            // secondary_window 为 null 或缺少 used_percent 时 parseWindow 会返回 nil；
            // 用 status 保留“该窗口不存在”的信息，供 UI 决定是否渲染。
            weeklyStatus: usage.secondary == nil ? .absent : .present,
            weeklyResetsAt: usage.secondary?.resetsAt,
            weeklyWindowSeconds: usage.secondary?.limitWindowSeconds
        )
    }

    private nonisolated static func positiveInt(_ raw: Any?) -> Int? {
        guard let number = strictJSONNumber(raw) else { return nil }
        let doubleValue = number.doubleValue
        guard doubleValue.isFinite,
              let value = Int(exactly: doubleValue),
              value > 0 else {
            return nil
        }
        return value
    }

    /// `JSONSerialization` 将 JSON number 和 bool 都桥接为 `NSNumber`。
    /// Swift 的 `raw is Bool` 会把部分数值 0/1 也视为 Bool，因此只能通过
    /// 区分真正的 JSON true/false，避免把 NSNumber 形式的 0/1 当成布尔值。
    private nonisolated static func strictJSONNumber(_ raw: Any?) -> NSNumber? {
        guard let number = raw as? NSNumber,
              !DateParser.isBoolean(number) else {
            return nil
        }
        return number
    }

    nonisolated static func parseResetCreditsData(_ data: Data) throws -> ResetCreditsResponse {
        let json: Any
        do { json = try JSONSerialization.jsonObject(with: data) }
        catch { throw QuotaError.decodingError("reset-credits 不是合法 JSON") }
        guard let dict = json as? [String: Any] else {
            throw QuotaError.decodingError("reset-credits 顶层不是对象")
        }

        // 顶层 metadata：字段存在就必须是严格非负整数。available_count 还必须
        // 在合成条目的安全上限内，非法响应交给上层保留旧数据。
        let serverAvailable: Int?
        if let raw = dict["available_count"] {
            guard let count = nonNegativeIntValue(raw),
                  count <= Self.maxResetCreditEntries else {
                throw QuotaError.decodingError(
                    "reset-credits.available_count 不是 0...\(Self.maxResetCreditEntries) 的整数"
                )
            }
            serverAvailable = count
        } else {
            serverAvailable = nil
        }

        let totalEarned: Int?
        if let raw = dict["total_earned_count"] {
            guard let count = nonNegativeIntValue(raw) else {
                throw QuotaError.decodingError(
                    "reset-credits.total_earned_count 不是合法非负整数"
                )
            }
            totalEarned = count
        } else {
            totalEarned = nil
        }

        let arr: [[String: Any]]
        if let rawCredits = dict["credits"] {
            guard let decoded = rawCredits as? [[String: Any]] else {
                throw QuotaError.decodingError("reset-credits.credits 不是对象数组")
            }
            guard decoded.count <= Self.maxResetCreditEntries else {
                throw QuotaError.decodingError(
                    "reset-credits.credits 超过 \(Self.maxResetCreditEntries) 条"
                )
            }
            arr = decoded
        } else {
            logWarn("[codex] reset-credits 响应无 credits 数组，使用 available_count 回退")
            arr = []
        }

        var entries: [ResetCreditEntry] = []
        for item in arr {
            let id = (item["id"] as? String) ?? UUID().uuidString
            let status = (item["status"] as? String) ?? "unknown"
            let expiresAt = DateParser.parse(item["expires_at"])
            let grantedAt = DateParser.parse(item["granted_at"])
            let resetType = item["reset_type"] as? String
            let title = item["title"] as? String
            let desc = item["description"] as? String
            entries.append(ResetCreditEntry(
                id: id,
                status: status,
                expiresAt: expiresAt,
                grantedAt: grantedAt,
                resetType: resetType,
                title: title,
                description: desc
            ))
        }

        // credits 可能缺失、为空或只返回 used/expired 子集。以服务端汇总为准补齐
        // 缺少的 available 条目，确保卡片数量与 hover 详情一致；总条目仍受统一上限。
        let parsedAvailableCount = entries.lazy.filter {
            $0.status.caseInsensitiveCompare("available") == .orderedSame
        }.count
        if let count = serverAvailable, count > parsedAvailableCount {
            let missingCount = count - parsedAvailableCount
            guard entries.count <= Self.maxResetCreditEntries - missingCount else {
                throw QuotaError.decodingError(
                    "reset-credits 补全可用条目后超过 \(Self.maxResetCreditEntries) 条"
                )
            }
            entries.reserveCapacity(entries.count + missingCount)
            entries.append(contentsOf: (0..<missingCount).map { i in
                ResetCreditEntry(
                    id: "synthetic-\(i)",
                    status: "available",
                    expiresAt: nil,
                    grantedAt: nil,
                    resetType: nil,
                    title: nil,
                    description: nil
                )
            })
        }

        return ResetCreditsResponse(
            entries: entries,
            serverAvailableCount: serverAvailable,
            totalEarnedCount: totalEarned
        )
    }

    private nonisolated static func safeWindowDurationDescription(
        _ window: ActiveUsageWindow
    ) -> String {
        let duration = window.resetDate.timeIntervalSince(window.startDate)
        guard duration.isFinite,
              duration >= 0,
              let seconds = Int(exactly: duration.rounded(.towardZero)) else {
            return "invalid"
        }
        return "\(seconds)s"
    }

}
