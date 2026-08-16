import Foundation

/// 以窗口范围和 session 文件指纹缓存本地统计，避免每 60 秒重复读取、解析同一批 JSONL。
actor CodexUsageDetailsCache {
    static let shared = CodexUsageDetailsCache()
    private static let maximumEntryCount = 16

    private struct Entry: Sendable {
        let windowFingerprint: String
        let sourceFingerprint: String
        let details: CodexUsageDetails
    }

    private var entries: [String: Entry] = [:]
    private var recency: [String] = []

    func value(for codexHome: URL, windowFingerprint: String, sourceFingerprint: String) -> CodexUsageDetails? {
        let key = codexHome.path
        guard let entry = entries[key],
              entry.windowFingerprint == windowFingerprint,
              entry.sourceFingerprint == sourceFingerprint else {
            return nil
        }
        touch(key)
        return entry.details
    }

    func store(
        _ details: CodexUsageDetails,
        for codexHome: URL,
        windowFingerprint: String,
        sourceFingerprint: String
    ) {
        let key = codexHome.path
        entries[key] = Entry(
            windowFingerprint: windowFingerprint,
            sourceFingerprint: sourceFingerprint,
            details: details
        )
        touch(key)
        while recency.count > Self.maximumEntryCount {
            entries.removeValue(forKey: recency.removeFirst())
        }
    }

    private func touch(_ key: String) {
        if let index = recency.firstIndex(of: key) {
            recency.remove(at: index)
        }
        recency.append(key)
    }
}

struct CodexTokenUsageEvent: Sendable {
    let inputTokens: Int
    let cachedInputTokens: Int
    let outputTokens: Int
    let reasoningOutputTokens: Int
}

enum CodexSessionEvent: Sendable {
    case taskStarted(timestamp: Date, turnID: String)
    case taskCompleted(timestamp: Date, turnID: String)
    case modelContext(timestamp: Date, modelName: String)
    case tokenCount(timestamp: Date, usage: CodexTokenUsageEvent)

    var timestamp: Date {
        switch self {
        case .taskStarted(let timestamp, _),
             .taskCompleted(let timestamp, _),
             .modelContext(let timestamp, _),
             .tokenCount(let timestamp, _):
            return timestamp
        }
    }
}

struct CodexSessionFileEvents: Sendable {
    let fileURL: URL
    let events: [CodexSessionEvent]
}

/// 枚举 session 时一次性捕获后续缓存、排序都会用到的元数据，避免对同一文件
/// 在过滤、排序、source fingerprint 和单文件 cache 阶段重复执行 resourceValues。
struct CodexSessionFileSnapshot: Sendable {
    let fileURL: URL
    let modifiedAt: Date
    let fileSize: Int

    var fingerprint: String {
        "\(modifiedAt.timeIntervalSince1970):\(fileSize)"
    }
}

/// 本地 session 文件是不受信任且可无限增长的输入。所有扫描入口共用这组硬上限；
/// 测试可注入较小值验证边界，而无需构造大型文件。
struct CodexLocalScanLimits: Sendable {
    static let production = CodexLocalScanLimits(
        maxSessionFiles: 1_024,
        maxEventsPerFile: 10_000,
        maxTotalParsedBytes: 256 * 1024 * 1024,
        maxJSONLLineBytes: 8 * 1024 * 1024,
        readChunkBytes: 64 * 1024,
        maxEventCacheEntries: 256,
        maxRecentSamples: 65_536
    )

    let maxSessionFiles: Int
    let maxEventsPerFile: Int
    let maxTotalParsedBytes: Int
    let maxJSONLLineBytes: Int
    let readChunkBytes: Int
    let maxEventCacheEntries: Int
    let maxRecentSamples: Int

    init(
        maxSessionFiles: Int,
        maxEventsPerFile: Int,
        maxTotalParsedBytes: Int,
        maxJSONLLineBytes: Int,
        readChunkBytes: Int = 64 * 1024,
        maxEventCacheEntries: Int = 256,
        maxRecentSamples: Int = 65_536
    ) {
        self.maxSessionFiles = max(maxSessionFiles, 1)
        self.maxEventsPerFile = max(maxEventsPerFile, 1)
        self.maxTotalParsedBytes = max(maxTotalParsedBytes, 1)
        self.maxJSONLLineBytes = max(maxJSONLLineBytes, 1)
        self.readChunkBytes = max(min(readChunkBytes, maxJSONLLineBytes), 1)
        self.maxEventCacheEntries = max(maxEventCacheEntries, 1)
        self.maxRecentSamples = max(maxRecentSamples, 1)
    }
}

/// 按文件 mtime + size 缓存已解析的 session 事件。活跃 JSONL 变更时只重解析该文件，
/// 昨日及更早的文件直接复用，避免每次刷新都做七天全量 JSON 解析。
private actor CodexSessionEventCache {
    static let shared = CodexSessionEventCache()

    private struct Entry: Sendable {
        let fingerprint: String
        let parsingFingerprint: String
        let events: [CodexSessionEvent]
        let parsedByteCount: Int
    }

    private var entries: [String: Entry] = [:]
    private var recency: [String] = []

    func events(
        for fileURL: URL,
        fingerprint: String,
        parsingFingerprint: String
    ) -> (events: [CodexSessionEvent], parsedByteCount: Int)? {
        let key = fileURL.path
        guard let entry = entries[key],
              entry.fingerprint == fingerprint,
              entry.parsingFingerprint == parsingFingerprint else {
            return nil
        }
        touch(key)
        return (entry.events, entry.parsedByteCount)
    }

    func store(
        _ events: [CodexSessionEvent],
        parsedByteCount: Int,
        for fileURL: URL,
        fingerprint: String,
        parsingFingerprint: String,
        maximumEntryCount: Int
    ) {
        let key = fileURL.path
        entries[key] = Entry(
            fingerprint: fingerprint,
            parsingFingerprint: parsingFingerprint,
            events: events,
            parsedByteCount: parsedByteCount
        )
        touch(key)
        while recency.count > maximumEntryCount {
            entries.removeValue(forKey: recency.removeFirst())
        }
    }

    func removeAll(except filePaths: Set<String>) {
        entries = entries.filter { filePaths.contains($0.key) }
        recency.removeAll { !filePaths.contains($0) }
    }

    private func touch(_ key: String) {
        if let index = recency.firstIndex(of: key) {
            recency.remove(at: index)
        }
        recency.append(key)
    }
}

extension CodexFetcher {
    struct ActiveUsageWindow {
        let startDate: Date
        let resetDate: Date
    }

    struct DailyUsageWindow {
        let startDate: Date
        let endDate: Date
    }

    private struct MutableUsageSummary {
        var prompts = 0
        var rounds = 0
        var inputTokens = 0
        var cachedInputTokens = 0
        var outputTokens = 0
        var reasoningOutputTokens = 0

        mutating func add(_ usage: CodexTokenUsageEvent) {
            rounds = Self.saturatingAdd(rounds, 1)
            inputTokens = Self.saturatingAdd(inputTokens, usage.inputTokens)
            cachedInputTokens = Self.saturatingAdd(
                cachedInputTokens,
                usage.cachedInputTokens
            )

            // QuotaInfo 的 reasonRate/outputTotal 会直接计算 output + reasoning；
            // 聚合时维持两者之和 <= Int.max，避免下游计算再次溢出。
            var remainingOutputBudget = Int.max - outputTokens - reasoningOutputTokens
            let acceptedOutput = min(usage.outputTokens, remainingOutputBudget)
            outputTokens += acceptedOutput
            remainingOutputBudget -= acceptedOutput
            reasoningOutputTokens += min(
                usage.reasoningOutputTokens,
                remainingOutputBudget
            )
        }

        func freeze() -> UsageMetricSummary {
            UsageMetricSummary(
                prompts: prompts,
                rounds: rounds,
                inputTokens: inputTokens,
                // 每个 event 已校验 cached <= input；最终再约束一次，使未来
                // 调用方也不能构造出 cache hit rate > 100% 的摘要。
                cachedInputTokens: min(cachedInputTokens, inputTokens),
                outputTokens: outputTokens,
                reasoningOutputTokens: reasoningOutputTokens
            )
        }

        private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
            let (sum, overflow) = lhs.addingReportingOverflow(rhs)
            return overflow ? Int.max : sum
        }
    }

    struct LocalUsageScanResult {
        let usageSummaries: [String: UsageMetricSummary]
        let dailyTokenUsage: [DailyTokenUsage]
        let recentSamples: [LocalTokenUsageSample]
        let latestPromptFile: URL?
        let latestPromptTurnID: String?
        let latestPromptCompletedAt: Date?
        let scannedFileCount: Int
    }

    nonisolated static func makeUsageWindows(from model: ModelQuota) -> [String: ActiveUsageWindow] {
        var windows: [String: ActiveUsageWindow] = [:]

        if let resetDate = model.intervalResetsAt {
            let windowSeconds = model.intervalWindowSeconds ?? (5 * 60 * 60)
            windows["primary"] = ActiveUsageWindow(
                startDate: resetDate.addingTimeInterval(-TimeInterval(windowSeconds)),
                resetDate: resetDate
            )
        }

        if let resetDate = model.weeklyResetsAt {
            let windowSeconds = model.weeklyWindowSeconds ?? (7 * 24 * 60 * 60)
            windows["secondary"] = ActiveUsageWindow(
                startDate: resetDate.addingTimeInterval(-TimeInterval(windowSeconds)),
                resetDate: resetDate
            )
        }

        return windows
    }

    nonisolated static func summarizeLocalUsage(
        windows: [String: ActiveUsageWindow],
        dailyWindows: [DailyUsageWindow],
        sessionFiles: [CodexSessionFileEvents],
        limits: CodexLocalScanLimits = .production
    ) -> LocalUsageScanResult {
        guard !windows.isEmpty else {
            return LocalUsageScanResult(
                usageSummaries: [:],
                dailyTokenUsage: [],
                recentSamples: [],
                latestPromptFile: nil,
                latestPromptTurnID: nil,
                latestPromptCompletedAt: nil,
                scannedFileCount: 0
            )
        }

        var tokenSummaries = Dictionary(
            uniqueKeysWithValues: windows.keys.map { ($0, MutableUsageSummary()) }
        )
        var promptIDs = Dictionary(
            uniqueKeysWithValues: windows.keys.map { ($0, Set<String>()) }
        )
        var dailySummaries = Dictionary(
            uniqueKeysWithValues: dailyWindows.map { ($0.startDate, MutableUsageSummary()) }
        )
        var dailyPromptIDs = Dictionary(
            uniqueKeysWithValues: dailyWindows.map { ($0.startDate, Set<String>()) }
        )
        var latestPromptFile: URL?
        var latestPromptTurnID: String?
        var latestPromptCompletedAt: Date?
        var recentSamples: [LocalTokenUsageSample] = []
        var scannedFileCount = 0

        logInfo("[codex/local] 候选 session files=\(sessionFiles.count)")

        for sessionFile in sessionFiles {
            guard !Task.isCancelled else { break }
            scannedFileCount += 1
            var activeTurnID: String?
            var currentModelName: String?
            for event in sessionFile.events {
                guard !Task.isCancelled else { break }
                let timestamp = event.timestamp
                let matchingKeys = windows.compactMap { key, window in
                    (window.startDate <= timestamp && timestamp < window.resetDate) ? key : nil
                }
                switch event {
                case .taskStarted(_, let turnID):
                    activeTurnID = turnID
                    for key in matchingKeys {
                        promptIDs[key, default: []].insert(turnID)
                    }
                    if let dailyWindow = dailyWindows.first(where: {
                        $0.startDate <= timestamp && timestamp < $0.endDate
                    }) {
                        dailyPromptIDs[dailyWindow.startDate, default: []].insert(turnID)
                    }
                case .taskCompleted(_, let turnID):
                    if activeTurnID == turnID {
                        activeTurnID = nil
                    }
                    guard !matchingKeys.isEmpty else { continue }
                    if latestPromptCompletedAt == nil || timestamp > latestPromptCompletedAt! {
                        latestPromptCompletedAt = timestamp
                        latestPromptFile = sessionFile.fileURL
                        latestPromptTurnID = turnID
                    }
                case .modelContext(_, let modelName):
                    currentModelName = modelName
                case .tokenCount(let timestamp, let usage):
                    for key in matchingKeys {
                        tokenSummaries[key, default: MutableUsageSummary()].add(usage)
                    }
                    if let dailyWindow = dailyWindows.first(where: {
                        $0.startDate <= timestamp && timestamp < $0.endDate
                    }) {
                        dailySummaries[dailyWindow.startDate, default: MutableUsageSummary()].add(usage)
                        // daily 汇总不要求 token_count 必须落在 taskStarted/taskCompleted
                        // 区间内；价格明细也必须保留这类记录，否则会出现“当天有 token、
                        // 但价值显示 —”。没有 active turn 时用时间戳生成稳定的明细 ID。
                        let promptID = activeTurnID.map {
                            "codex:\($0)"
                        } ?? "codex:orphan:\(timestamp.timeIntervalSince1970)"
                        recentSamples.append(
                            LocalTokenUsageSample(
                                completedAt: timestamp,
                                modelName: currentModelName,
                                promptID: promptID,
                                inputTokens: usage.inputTokens,
                                cachedInputTokens: usage.cachedInputTokens,
                                outputTokens: usage.outputTokens,
                                reasoningOutputTokens: usage.reasoningOutputTokens,
                                sourceProviderID: QuotaProviderID.openAI
                            )
                        )
                    }
                }
            }
        }

        var usageSummaries: [String: UsageMetricSummary] = [:]
        for key in windows.keys {
            var summary = tokenSummaries[key] ?? MutableUsageSummary()
            summary.prompts = promptIDs[key]?.count ?? 0
            usageSummaries[key] = summary.freeze()
        }
        let dailyTokenUsage = dailyWindows.map { window in
            var summary = dailySummaries[window.startDate] ?? MutableUsageSummary()
            summary.prompts = dailyPromptIDs[window.startDate]?.count ?? 0
            let frozen = summary.freeze()
            return DailyTokenUsage(
                dayStart: window.startDate,
                inputTokens: frozen.inputTokens,
                cachedInputTokens: frozen.cachedInputTokens,
                outputTokens: frozen.outputTokens,
                reasoningOutputTokens: frozen.reasoningOutputTokens,
                rounds: frozen.rounds,
                turns: frozen.prompts
            )
        }
        logInfo(
            "[codex/local] 扫描完成：files=\(scannedFileCount), "
                + "hasLatestPrompt=\(latestPromptFile != nil)"
        )
        for day in dailyTokenUsage {
            let key = Formatters.formatMonthDay(day.dayStart)
            logDebug("[codex/local/day] \(key): turns=\(day.turns), rounds=\(day.rounds), input=\(day.inputTokens), cached=\(day.cachedInputTokens), output=\(day.outputTokens), reason=\(day.reasoningOutputTokens)")
        }
        let sortedSamples = recentSamples.sorted { $0.completedAt < $1.completedAt }
        let boundedSamples = sortedSamples.count > limits.maxRecentSamples
            ? Array(sortedSamples.suffix(limits.maxRecentSamples))
            : sortedSamples
        let sampleModelNames = Dictionary(grouping: boundedSamples) {
            $0.modelName ?? "<missing>"
        }
        logDebug(
            "[codex/local] price samples=\(boundedSamples.count), "
                + "models=\(sampleModelNames.map { "\($0.key):\($0.value.count)" }.sorted().joined(separator: ", "))"
        )
        for key in windows.keys.sorted() {
            let summary = usageSummaries[key]
            logDebug("[codex/local] \(key): prompts=\(summary?.prompts ?? 0), rounds=\(summary?.rounds ?? 0), input=\(summary?.inputTokens ?? 0), output=\(summary?.outputTokens ?? 0), reasoning=\(summary?.reasoningOutputTokens ?? 0)")
        }
        return LocalUsageScanResult(
            usageSummaries: usageSummaries,
            dailyTokenUsage: dailyTokenUsage,
            // 与 DSH scanner 对齐：samples 跨多个 session 文件拼接后按时间排序，
            // 保证 UI 在 `samplesInDisplayedWindow` / `todaySamples` 这类按日期过滤
            // 的逻辑下不会因为文件读取顺序错乱而漏掉 sample，且保留最新的 maxRecentSamples 条。
            recentSamples: boundedSamples,
            latestPromptFile: latestPromptFile,
            latestPromptTurnID: latestPromptTurnID,
            latestPromptCompletedAt: latestPromptCompletedAt,
            scannedFileCount: scannedFileCount
        )
    }

    nonisolated static func latestPromptUsage(
        sessionFiles: [CodexSessionFileEvents],
        fileURL: URL?,
        turnID: String?,
        completedAt: Date?
    ) -> LastPromptUsage? {
        guard let fileURL,
              let turnID,
              let completedAt,
              let events = sessionFiles.first(where: { $0.fileURL == fileURL })?.events else {
            return nil
        }

        var startedAt: Date?
        var summary = MutableUsageSummary()

        for event in events {
            guard !Task.isCancelled else { return nil }
            switch event {
            case .taskStarted(let timestamp, let eventTurnID):
                if eventTurnID == turnID {
                    startedAt = timestamp
                }
            case .tokenCount(let timestamp, let usage):
                guard let startedAt,
                      startedAt <= timestamp,
                      timestamp <= completedAt else {
                    continue
                }
                summary.add(usage)
            case .modelContext:
                continue
            case .taskCompleted:
                continue
            }
        }

        guard startedAt != nil else { return nil }
        let frozen = summary.freeze()
        logDebug("[codex/local] lastPrompt: rounds=\(frozen.rounds), input=\(frozen.inputTokens), output=\(frozen.outputTokens), reasoning=\(frozen.reasoningOutputTokens)")
        return LastPromptUsage(completedAt: completedAt, usage: frozen)
    }

    nonisolated static func cachedSessionEvents(
        for snapshots: [CodexSessionFileSnapshot],
        limits: CodexLocalScanLimits = .production
    ) async -> [CodexSessionFileEvents] {
        let selectedSnapshots = mostRecentSnapshots(
            snapshots,
            maximumCount: limits.maxSessionFiles
        )
        await CodexSessionEventCache.shared.removeAll(
            except: Set(selectedSnapshots.map(\.fileURL.path))
        )

        var sessionFiles: [CodexSessionFileEvents] = []
        var parsedFileCount = 0
        var remainingByteBudget = limits.maxTotalParsedBytes
        for snapshot in selectedSnapshots {
            guard !Task.isCancelled else { break }
            guard remainingByteBudget > 0 else { break }
            let fileURL = snapshot.fileURL
            let fingerprint = snapshot.fingerprint
            let perFileByteLimit = min(max(snapshot.fileSize, 0), remainingByteBudget)
            guard perFileByteLimit > 0 else { continue }
            let parsingFingerprint = [
                // F2: 策略版本 v7——修复 turn ID 生成逻辑
                "v7",
                String(limits.maxEventsPerFile),
                String(perFileByteLimit),
                String(limits.maxJSONLLineBytes),
            ].joined(separator: ":")
            let events: [CodexSessionEvent]
            let parsedByteCount: Int
            if let cached = await CodexSessionEventCache.shared.events(
                for: fileURL,
                fingerprint: fingerprint,
                parsingFingerprint: parsingFingerprint
            ) {
                events = cached.events
                parsedByteCount = cached.parsedByteCount
            } else {
                let parsed = parseSessionEvents(
                    from: fileURL,
                    fileSize: snapshot.fileSize,
                    byteLimit: perFileByteLimit,
                    limits: limits
                )
                events = parsed.events
                parsedByteCount = parsed.parsedByteCount
                guard !Task.isCancelled else { break }
                await CodexSessionEventCache.shared.store(
                    events,
                    parsedByteCount: parsedByteCount,
                    for: fileURL,
                    fingerprint: fingerprint,
                    parsingFingerprint: parsingFingerprint,
                    maximumEntryCount: limits.maxEventCacheEntries
                )
                parsedFileCount += 1
            }
            remainingByteBudget -= min(parsedByteCount, remainingByteBudget)
            sessionFiles.append(CodexSessionFileEvents(fileURL: fileURL, events: events))
        }
        logInfo(
            "[codex/local] session cache: selected=\(selectedSnapshots.count), "
                + "loaded=\(sessionFiles.count), parsed=\(parsedFileCount)"
        )
        return sessionFiles
    }

    private nonisolated static func parseSessionEvents(
        from fileURL: URL,
        fileSize: Int,
        byteLimit: Int,
        limits: CodexLocalScanLimits
    ) -> (events: [CodexSessionEvent], parsedByteCount: Int) {
        // F2: 不在收集到 N 个事件时提前停止——否则读取文件头部时会保留最旧 N 个。
        // 改用容量为 maxEventsPerFile 的有界缓冲，仅保留最后 N 个已解析相关事件。
        // 超量时批量裁剪，摊销 O(1)，缓冲瞬时最多持有 2N 个紧凑事件。
        //
        // 边界：若某个逻辑 turn 的 task_started 落在尾部字节窗口之外（被截断丢弃），
        // 该 turn 的 prompt 统计会缺失——这是可接受的。不得因此回退到读取文件头，
        // 否则会重新引入“保留最旧事件”的错误语义。
        let maxEvents = limits.maxEventsPerFile
        var events: [CodexSessionEvent] = []
        events.reserveCapacity(min(maxEvents, 1024))
        let parsedByteCount = enumerateUTF8Lines(
            in: fileURL,
            fileSize: fileSize,
            byteLimit: byteLimit,
            maxLineBytes: limits.maxJSONLLineBytes,
            readChunkBytes: limits.readChunkBytes
        ) { line in
            guard !Task.isCancelled else { return false }
            // Performance optimization: skip JSON deserialization for non-event or irrelevant lines
            guard line.contains("event_msg") || line.contains("turn_context") else { return true }
            guard line.contains("task_started") || line.contains("task_complete") || line.contains("token_count") || line.contains("turn_context") else { return true }

            guard let object = parseJSONObject(from: line),
                  let timestamp = DateParser.parse(object["timestamp"]),
                  let payload = object["payload"] as? [String: Any] else {
                return true
            }

            if object["type"] as? String == "turn_context",
               let modelName = payload["model"] as? String,
               !modelName.isEmpty {
                events.append(.modelContext(timestamp: timestamp, modelName: modelName))
                return true
            }

            guard object["type"] as? String == "event_msg",
                  let payloadType = payload["type"] as? String else {
                return true
            }

            switch payloadType {
            case "task_started":
                if let turnID = payload["turn_id"] as? String {
                    events.append(.taskStarted(timestamp: timestamp, turnID: turnID))
                }
            case "task_complete":
                if let turnID = payload["turn_id"] as? String {
                    events.append(.taskCompleted(timestamp: timestamp, turnID: turnID))
                }
            case "token_count":
                guard let info = payload["info"] as? [String: Any],
                      let usage = info["last_token_usage"] as? [String: Any],
                      let inputTokens = nonNegativeIntValue(usage["input_tokens"]),
                      let cachedInputTokens = nonNegativeIntValue(usage["cached_input_tokens"]),
                      let outputTokens = nonNegativeIntValue(usage["output_tokens"]),
                      let reasoningOutputTokens = nonNegativeIntValue(
                          usage["reasoning_output_tokens"]
                      ),
                      cachedInputTokens <= inputTokens else {
                    return true
                }
                events.append(
                    .tokenCount(
                        timestamp: timestamp,
                        usage: CodexTokenUsageEvent(
                            inputTokens: inputTokens,
                            cachedInputTokens: cachedInputTokens,
                            outputTokens: outputTokens,
                            reasoningOutputTokens: reasoningOutputTokens
                        )
                    )
                )
            default:
                break
            }

            // F2: 有界缓冲——不提前停止，仅在超量时保留最后 N 个相关事件。
            // 这样从文件尾读取时结果严格为最后 N 个，而读取头部时不会被截断成最旧 N 个。
            if events.count >= maxEvents * 2 {
                events.removeFirst(maxEvents)
            }
            return true
        }
        // 总扫描预算必须按实际读取字节扣减，而不是只计算匹配到的 event 行。
        // 否则大量无关/损坏内容可以让每个文件都重复享用完整预算，失去 CPU/I/O
        // DoS 硬上界。production 的 256 MiB 仍足以覆盖正常七天 session 集。
        if events.count > maxEvents {
            events.removeFirst(events.count - maxEvents)
        }
        return (events, parsedByteCount)
    }



    /// 返回今天和之前六天的本地自然日，边界严格为 00:00:00 至下一天 00:00:00。
    nonisolated static func recentDailyUsageWindows(
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [DailyUsageWindow] {
        let today = calendar.startOfDay(for: now)
        return (-6...0).compactMap { offset in
            guard let startDate = calendar.date(byAdding: .day, value: offset, to: today),
                  let endDate = calendar.date(byAdding: .day, value: 1, to: startDate) else {
                return nil
            }
            return DailyUsageWindow(startDate: startDate, endDate: endDate)
        }
    }

    nonisolated static func localUsageWindowFingerprint(
        _ windows: [String: ActiveUsageWindow],
        dailyWindows: [DailyUsageWindow]
    ) -> String {
        let rateLimitFingerprint = windows
            .map { key, window in
                "\(key):\(window.startDate.timeIntervalSince1970):\(window.resetDate.timeIntervalSince1970)"
            }
            .sorted()
            .joined(separator: "|")
        let dailyFingerprint = dailyWindows
            .map { "daily:\($0.startDate.timeIntervalSince1970):\($0.endDate.timeIntervalSince1970)" }
            .joined(separator: "|")
        return "v4|\(rateLimitFingerprint)|\(dailyFingerprint)"
    }

    /// 仅从 logDebug 的 @autoclosure 内调用，Release 不会创建 formatter。
    nonisolated static func debugUsageWindowDescriptions(
        _ windows: [String: ActiveUsageWindow]
    ) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return windows.map { key, window in
            "\(key): [\(formatter.string(from: window.startDate)) → \(formatter.string(from: window.resetDate))]"
        }
        .sorted()
        .joined(separator: ", ")
    }

    /// 仅从 logDebug 的 @autoclosure 内调用，Release 不会创建 formatter。
    nonisolated static func debugDailyWindowDescriptions(
        _ windows: [DailyUsageWindow]
    ) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return windows.map {
            "[\(formatter.string(from: $0.startDate)) → \(formatter.string(from: $0.endDate))]"
        }
        .joined(separator: ", ")
    }

    nonisolated static func localUsageSourceFingerprint(
        _ files: [CodexSessionFileSnapshot]
    ) -> String {
        files.map { snapshot in
            "\(snapshot.fileURL.path):\(snapshot.fingerprint)"
        }
        .joined(separator: "|")
    }

    nonisolated static func sessionFiles(
        codexHome: URL,
        modifiedSince: Date?,
        limits: CodexLocalScanLimits = .production
    ) -> [CodexSessionFileSnapshot] {
        let roots = [
            codexHome.appendingPathComponent("sessions", isDirectory: true),
            codexHome.appendingPathComponent("archived_sessions", isDirectory: true),
        ]
        let fm = FileManager.default
        var files: [CodexSessionFileSnapshot] = []
        let cutoff = modifiedSince?.addingTimeInterval(-6 * 60 * 60)

        for root in roots {
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for case let fileURL as URL in enumerator {
                guard !Task.isCancelled else { return files }
                guard fileURL.pathExtension == "jsonl" else { continue }
                guard let values = try? fileURL.resourceValues(
                    forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
                ), values.isRegularFile == true else {
                    continue
                }
                let modifiedAt = values.contentModificationDate ?? .distantPast
                if let cutoff {
                    guard modifiedAt >= cutoff else { continue }
                }
                insertRecentSnapshot(
                    CodexSessionFileSnapshot(
                        fileURL: fileURL,
                        modifiedAt: modifiedAt,
                        fileSize: max(values.fileSize ?? 0, 0)
                    ),
                    into: &files,
                    maximumCount: limits.maxSessionFiles
                )
            }
        }

        return files
    }

    private nonisolated static func mostRecentSnapshots(
        _ snapshots: [CodexSessionFileSnapshot],
        maximumCount: Int
    ) -> [CodexSessionFileSnapshot] {
        var selected: [CodexSessionFileSnapshot] = []
        selected.reserveCapacity(min(snapshots.count, maximumCount))
        for snapshot in snapshots {
            insertRecentSnapshot(
                snapshot,
                into: &selected,
                maximumCount: maximumCount
            )
        }
        return selected
    }

    private nonisolated static func insertRecentSnapshot(
        _ snapshot: CodexSessionFileSnapshot,
        into snapshots: inout [CodexSessionFileSnapshot],
        maximumCount: Int
    ) {
        let insertionIndex = snapshots.firstIndex {
            if $0.modifiedAt != snapshot.modifiedAt {
                return $0.modifiedAt < snapshot.modifiedAt
            }
            return $0.fileURL.path < snapshot.fileURL.path
        } ?? snapshots.endIndex
        snapshots.insert(snapshot, at: insertionIndex)
        if snapshots.count > maximumCount {
            snapshots.removeLast()
        }
    }

    /// 以固定大小 chunk 读取 JSONL，避免大型活跃 session 被一次性载入内存。
    /// 只读取文件尾部 `byteLimit` 字节以优先保留近期事件；起点落在行中时丢弃
    /// 到第一个换行符，从下一完整行开始解析。单行超限会被丢弃至下一个换行符。
    /// pending、单文件读取量和整个扫描读取量都有明确硬上限。handler 返回 false
    /// 时立刻停止，供任务取消快速退出。seek/读取失败给出明确诊断并返回 0，而不是
    /// 静默退化为从文件头读取（那样会保留最旧事件，与“保留近期事件”语义相反）。
    @discardableResult
    private nonisolated static func enumerateUTF8Lines(
        in fileURL: URL,
        fileSize: Int,
        byteLimit: Int,
        maxLineBytes: Int,
        readChunkBytes: Int,
        handler: (String) -> Bool
    ) -> Int {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            logWarn("[codex/local] 打开 session 文件失败，跳过: \(fileURL.lastPathComponent)")
            return 0
        }
        defer { try? handle.close() }

        // 以 handle 实测的文件长度为准，处理 snapshot 之后文件增长或截断；
        // 不得直接信任调用方传入的 fileSize。
        let actualEndOffset: UInt64
        if let end = try? handle.seekToEnd() {
            actualEndOffset = end
        } else {
            logWarn("[codex/local] 无法确定 session 文件长度，跳过: \(fileURL.lastPathComponent)")
            return 0
        }
        let actualLength = Int(actualEndOffset)
        let safeByteLimit = max(min(byteLimit, actualLength), 0)
        guard safeByteLimit > 0 else { return 0 }

        // 字节预算只覆盖文件尾部。startOffset == 0 时第一行完整，不得丢弃首行；
        // startOffset > 0 时 seek 到起点并丢弃到第一个换行符。
        // 注意：上面 seekToEnd() 把文件指针移到了末尾，因此即使 startOffset == 0
        // 也必须显式 seek 回起点，否则后续 read 立刻 EOF。
        let startOffset = actualLength - safeByteLimit
        do {
            try handle.seek(toOffset: UInt64(startOffset))
        } catch {
            logWarn("[codex/local] seek 到文件尾部失败，跳过: \(fileURL.lastPathComponent)")
            return 0
        }
        var discardingInitialPartialLine = startOffset > 0
        _ = fileSize  // 保留参数以稳定签名，实际限额以 handle 实测长度为准

        var pending = Data()
        pending.reserveCapacity(min(maxLineBytes, readChunkBytes))
        var discardingOversizedLine = false

        var bytesRead = 0
        while !Task.isCancelled, bytesRead < safeByteLimit {
            let nextReadSize = min(readChunkBytes, safeByteLimit - bytesRead)
            guard let chunk = try? handle.read(upToCount: nextReadSize),
                  !chunk.isEmpty else {
                break
            }
            bytesRead += chunk.count

            var segmentStart = chunk.startIndex
            while let newline = chunk[segmentStart...].firstIndex(of: 0x0A) {
                let segment = chunk[segmentStart..<newline]
                if discardingInitialPartialLine {
                    // 起点落在某行中间，丢弃首段残行；下一个换行符之后恢复解析。
                    discardingInitialPartialLine = false
                } else if discardingOversizedLine {
                    // 已丢弃此前的超限前缀；换行符结束该坏行，下一段恢复解析。
                    discardingOversizedLine = false
                } else if segment.count <= maxLineBytes - pending.count {
                    pending.append(segment)
                    let line = String(decoding: pending, as: UTF8.self)
                    pending.removeAll(keepingCapacity: true)
                    if !handler(line) { return bytesRead }
                } else {
                    pending.removeAll(keepingCapacity: false)
                    logWarn("[codex/local] 跳过超限 JSONL 行（上限 \(maxLineBytes) bytes）")
                }
                segmentStart = chunk.index(after: newline)
            }

            let tail = chunk[segmentStart...]
            guard !discardingInitialPartialLine, !discardingOversizedLine else { continue }
            if tail.count <= maxLineBytes - pending.count {
                pending.append(tail)
            } else {
                pending.removeAll(keepingCapacity: false)
                discardingOversizedLine = true
                logWarn("[codex/local] 跳过超限 JSONL 行（上限 \(maxLineBytes) bytes）")
            }
        }

        if !Task.isCancelled,
           !discardingInitialPartialLine,
           !discardingOversizedLine,
           !pending.isEmpty {
            _ = handler(String(decoding: pending, as: UTF8.self))
        }
        return bytesRead
    }

    private nonisolated static func parseJSONObject(from line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            logDebug("[codex/local] 跳过无效 JSONL 行（\(line.utf8.count) bytes）")
            return nil
        }
        return object
    }

    /// JSON token/count 字段的严格转换：Bool、负数、小数、NaN/Infinity 及
    /// 超出 Int 范围的值全部拒绝，不做 NSNumber.intValue 的截断转换。
    nonisolated static func nonNegativeIntValue(_ raw: Any?) -> Int? {
        if let value = raw as? NSNumber {
            // `raw is Bool` 不能用于 JSON 类型判别：Foundation 会把数值 0/1
            // 的 NSNumber 也桥接成 Bool，导致合法计数字段被误拒绝。通过共享 helper
            // 只排除 JSON true/false。
            guard !DateParser.isBoolean(value) else {
                return nil
            }
            let double = value.doubleValue
            guard double.isFinite,
                  double >= 0,
                  let exact = Int(exactly: double) else {
                return nil
            }
            return exact
        }
        if let value = raw as? Int {
            return value >= 0 ? value : nil
        }
        if let value = raw as? String,
           let int = Int(value),
           int >= 0 {
            return int
        }
        return nil
    }
}
