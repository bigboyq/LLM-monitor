import Foundation

// MARK: - 报告构建（§6.3）

/// 副节点报告的构建输入：身份、配置与当前 UI 同源的状态快照。
struct UsageReportInput {
    let identity: NodeIdentity
    let nodeName: String
    let bindings: [ClientProviderBinding]
    let statuses: [ProviderStatus]
    var now: Date = Date()
    var calendar: Calendar = .current

    init(
        identity: NodeIdentity,
        nodeName: String,
        bindings: [ClientProviderBinding],
        statuses: [ProviderStatus],
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
        self.identity = identity
        self.nodeName = nodeName
        self.bindings = bindings
        self.statuses = statuses
        self.now = now
        self.calendar = calendar
    }
}

/// 从本机已投影的内存状态构建 `NodeUsageReport`。
///
/// 数据口径全部沿用现有链路，不新增第二套计价 / 归因路径（§11）：
/// - 每日 totals / clientProviders 来自 `ProviderStatus.usageProjection` 的
///   权威日聚合（L1 帧 → L2 内核投影，归属已裁决）；
/// - 模型明细 entries 从 `recentSamples` 分组，金额走
///   `ModelPricingCatalog.estimate`（金额与 token 同一批样本）；
/// - 窗口摘要按各 model 的真实窗口边界筛样本（同样本计价），
///   GLM 闲时窗口单独成行（`windowKind = glmOffPeak`）；
/// - 额度通道只报有有效 `lastSuccess` 的 provider（§5.1）。
///
/// seq 由 `NodeIdentityStore.allocateSeq()` 在发送前持久化分配，这里只填充。
enum UsageReportBuilder {
    static func build(_ input: UsageReportInput, seq: Int) -> NodeUsageReport {
        var entryRows: [EntryKey: EntryAccumulator] = [:]
        var clientDayRows: [ClientDayKey: FleetClientProviderUsage] = [:]
        var anySourceIncomplete = false

        for status in input.statuses {
            let projection = status.usageProjection(for: status.lastSuccess, now: input.now)
            let quotaProviderID = status.kind.quotaProviderID

            for contribution in projection.contributions {
                if contribution.isTruncated || projection.localUsageFreshness == .failed {
                    anySourceIncomplete = true
                }
                for day in contribution.dailyTokenUsage {
                    let dayKey = FleetMerger.dayKey(of: day.dayStart, calendar: input.calendar)
                    let key = ClientDayKey(
                        dayKey: dayKey,
                        clientID: contribution.clientID,
                        quotaProviderID: quotaProviderID
                    )
                    clientDayRows[key] = Self.mergedClientDayRow(
                        existing: clientDayRows[key],
                        key: key,
                        day: day
                    )
                }
                for sample in contribution.recentSamples {
                    let dayKey = FleetMerger.dayKey(of: sample.completedAt, calendar: input.calendar)
                    let key = EntryKey(
                        dayKey: dayKey,
                        clientID: contribution.clientID,
                        quotaProviderID: quotaProviderID,
                        modelName: HarnessTodaySummary.normalizedModelName(sample.modelName)
                    )
                    entryRows[key, default: EntryAccumulator(key: key, quotaProviderID: quotaProviderID)]
                        .add(sample: sample, truncated: contribution.isTruncated)
                }
            }
        }

        let dayKeys = FleetMerger.dayKeyWindow(now: input.now, calendar: input.calendar)
        var buckets: [FleetDailyBucket] = []
        for dayKey in dayKeys {
            var matchingClientRows: [FleetClientProviderUsage] = []
            for (key, row) in clientDayRows where key.dayKey == dayKey {
                matchingClientRows.append(row)
            }
            let clientRows = matchingClientRows.sorted {
                ($0.clientID, $0.quotaProviderID) < ($1.clientID, $1.quotaProviderID)
            }
            // 权威 totals 是日聚合的规范化汇总（§5.1），不由模型明细反推。
            let totals = FleetTotals(summing: clientRows)
            let entries = entryRows
                .filter { $0.key.dayKey == dayKey }
                .values
                .map(\.finalized)
                .sorted {
                    ($0.clientID, $0.quotaProviderID, $0.modelName ?? "")
                        < ($1.clientID, $1.quotaProviderID, $1.modelName ?? "")
                }
            buckets.append(FleetDailyBucket(
                dayKey: dayKey,
                totals: totals,
                clientProviders: clientRows,
                entries: entries,
                totalsComplete: !anySourceIncomplete,
                modelDetailsComplete: !anySourceIncomplete,
                sourceTruncated: anySourceIncomplete
            ))
        }

        let windowRows = input.statuses.flatMap { status in
            buildWindowRows(status: status, now: input.now)
        }
        let quotaReports = input.statuses.compactMap { status -> FleetQuotaReport? in
            guard status.isEnabled, let info = status.lastSuccess else { return nil }
            let report = quotaReport(status: status, info: info)
            return report.hasActiveQuotaWindow ? report : nil
        }

        // reconcile 跑动中不宣称权威日总量：省略整条日桶通道（§6.3——缓存
        // 恢复值不等于已验证，不能当权威零值覆盖 hub），额度/心跳照常。
        let anyScanning = input.statuses.contains {
            $0.isScanningLocalUsage || $0.effectiveLocalUsageFreshness == .scanning
        }

        return NodeUsageReport(
            protocolVersion: FleetProtocol.version,
            node: FleetNodeIdentity(
                nodeID: input.identity.nodeID,
                nodeName: input.nodeName,
                timezoneID: TimeZone.current.identifier,
                platform: "macOS"
            ),
            seq: seq,
            generatedAt: input.now,
            attributionFingerprint: FleetAttributionFingerprint.compute(input.bindings),
            dailyBuckets: anyScanning ? nil : buckets,
            windowUsage: windowRows,
            quotas: quotaReports
        )
    }

    // MARK: 额度通道

    /// DTO 带余额明细、裁掉与用量重复的 `codexUsageDetails`（§5.1）。
    static func quotaReport(status: ProviderStatus, info: QuotaInfo) -> FleetQuotaReport {
        FleetQuotaReport(
            quotaProviderID: status.kind.quotaProviderID,
            fetchedAt: info.fetchedAt,
            models: info.models,
            resetCredits: info.resetCredits,
            planLabel: info.planLabel,
            accountEmail: info.accountEmail,
            balanceDetail: info.balanceDetail
        )
    }

    // MARK: 窗口通道

    /// 按 provider 每个 model 的真实窗口边界筛样本、同样本计价；
    /// GLM 闲时任务窗口单独成行（真实边界，§10.7.1）。
    static func buildWindowRows(status: ProviderStatus, now: Date) -> [FleetWindowUsage] {
        guard let info = status.lastSuccess else { return [] }
        let quotaProviderID = status.kind.quotaProviderID
        let projection = status.usageProjection(for: info, now: now)
        let samples = projection.recentSamples
        let truncated = projection.isTruncated
        let peakWindow = status.deepseekPeakWindow ?? DeepseekPeakWindow.defaultWindow
        var rows: [FleetWindowUsage] = []

        for model in info.models {
            func windowRow(
                _ kind: String,
                resetsAt: Date?,
                windowSeconds: Int?,
                fallbackSeconds: TimeInterval
            ) -> FleetWindowUsage? {
                guard let bounds = LocalUsageSummaryBuilder.windowBounds(
                    resetsAt: resetsAt,
                    explicitWindowSeconds: windowSeconds,
                    fallbackSeconds: fallbackSeconds,
                    now: now
                ) else { return nil }
                let matched = LocalUsageSummaryBuilder.windowSamples(
                    samples: samples,
                    providerKind: status.kind,
                    quotaModelName: model.modelName,
                    start: bounds.start,
                    end: bounds.end,
                    excludeWindows: status.glmOffPeakWindows,
                    excludeGlmOffPeak: status.kind == .glmCodingPlan
                )
                return windowUsageRow(
                    quotaProviderID: quotaProviderID,
                    modelID: model.modelName,
                    windowKind: kind,
                    bounds: bounds,
                    samples: matched,
                    observedAt: now,
                    truncated: truncated,
                    quotaProviderIDForPricing: quotaProviderID,
                    peakWindow: peakWindow
                )
            }

            if model.hasIntervalWindow, let row = windowRow(
                "interval",
                resetsAt: model.intervalResetsAt,
                windowSeconds: model.intervalWindowSeconds,
                fallbackSeconds: 5 * 60 * 60
            ) {
                rows.append(row)
            }
            if model.hasWeeklyWindow, let row = windowRow(
                "weekly",
                resetsAt: model.weeklyResetsAt,
                windowSeconds: model.weeklyWindowSeconds,
                fallbackSeconds: 7 * 24 * 60 * 60
            ) {
                rows.append(row)
            }
        }

        // GLM 闲时：每个闲时任务窗口一行（真实起止），样本与金额同样同源。
        if status.kind == .glmCodingPlan {
            for window in status.glmOffPeakWindows {
                let matched = samples.filter { window.contains($0.completedAt) }
                guard let row = windowUsageRow(
                    quotaProviderID: quotaProviderID,
                    modelID: "glm_coding_plan",
                    windowKind: "glmOffPeak",
                    bounds: LocalUsageWindowBounds(start: window.startedAt, end: window.endedAt),
                    samples: matched,
                    observedAt: now,
                    truncated: truncated,
                    quotaProviderIDForPricing: quotaProviderID,
                    peakWindow: peakWindow
                ) else { continue }
                rows.append(row)
            }
        }
        return rows
    }

    private static func windowUsageRow(
        quotaProviderID: String,
        modelID: String,
        windowKind: String,
        bounds: LocalUsageWindowBounds,
        samples: [LocalTokenUsageSample],
        observedAt: Date,
        truncated: Bool,
        quotaProviderIDForPricing: String,
        peakWindow: DeepseekPeakWindow
    ) -> FleetWindowUsage? {
        let cost = ModelPricingCatalog.estimate(
            samples: samples,
            quotaProviderID: quotaProviderIDForPricing,
            deepseekPeakWindow: peakWindow
        )
        let coverage = FleetCostCoverage(
            priced: cost.hasPrice,
            fullyPriced: cost.coverage == .fullyPriced,
            complete: !truncated
        )
        // 与日聚合同口径的四桶（uncached input / cacheRead 分列）。
        let tokenSums = samples.map(TokenUsageBuckets.fromSample).reduce(TokenUsageBuckets.zero) { acc, next in
            TokenUsageBuckets(
                input: SaturatingArithmetic.add(acc.input, next.input),
                cacheRead: SaturatingArithmetic.add(acc.cacheRead, next.cacheRead),
                output: SaturatingArithmetic.add(acc.output, next.output),
                reasoning: SaturatingArithmetic.add(acc.reasoning, next.reasoning)
            )
        }
        return FleetWindowUsage(
            quotaProviderID: quotaProviderID,
            modelID: modelID,
            windowKind: windowKind,
            startAt: bounds.start,
            endAt: bounds.end,
            observedAt: observedAt,
            input: tokenSums.input,
            cacheRead: tokenSums.cacheRead,
            output: tokenSums.output,
            reasoning: tokenSums.reasoning,
            value: cost.value,
            currency: cost.currency,
            coverage: coverage,
            complete: !truncated,
            sourceTruncated: truncated
        )
    }

    // MARK: 明细聚合

    /// 同一 (day, client, provider) 的日桶行合并（饱和加法）。
    private static func mergedClientDayRow(
        existing: FleetClientProviderUsage?,
        key: ClientDayKey,
        day: UnifiedDailyTokenUsage
    ) -> FleetClientProviderUsage {
        let base = existing ?? FleetClientProviderUsage(
            clientID: key.clientID,
            quotaProviderID: key.quotaProviderID,
            input: 0, cacheRead: 0, output: 0, reasoning: 0, turns: 0, rounds: 0
        )
        return FleetClientProviderUsage(
            clientID: base.clientID,
            quotaProviderID: base.quotaProviderID,
            input: SaturatingArithmetic.add(base.input, day.input),
            cacheRead: SaturatingArithmetic.add(base.cacheRead, day.cacheRead),
            output: SaturatingArithmetic.add(base.output, day.output),
            reasoning: SaturatingArithmetic.add(base.reasoning, day.reasoning),
            turns: SaturatingArithmetic.add(base.turns, day.turns),
            rounds: SaturatingArithmetic.add(base.rounds, day.rounds)
        )
    }

    private struct EntryKey: Hashable {
        let dayKey: String
        let clientID: String
        let quotaProviderID: String
        let modelName: String?
    }

    private struct ClientDayKey: Hashable {
        let dayKey: String
        let clientID: String
        let quotaProviderID: String
    }

    /// 模型明细行：token 从样本聚合，金额由同一批样本计价（同源硬纪律）。
    private struct EntryAccumulator {
        let key: EntryKey
        let quotaProviderID: String
        var input = 0, cacheRead = 0, output = 0, reasoning = 0
        var samples: [LocalTokenUsageSample] = []
        var truncated = false

        init(key: EntryKey, quotaProviderID: String) {
            self.key = key
            self.quotaProviderID = quotaProviderID
        }

        mutating func add(sample: LocalTokenUsageSample, truncated: Bool) {
            // 与日聚合同一套规范化口径（TokenUsageBuckets.fromSample）：
            // input 是 uncached，cacheRead 单列——entries 与 totals 才能对账。
            let buckets = TokenUsageBuckets.fromSample(sample)
            input = SaturatingArithmetic.add(input, buckets.input)
            cacheRead = SaturatingArithmetic.add(cacheRead, buckets.cacheRead)
            output = SaturatingArithmetic.add(output, buckets.output)
            reasoning = SaturatingArithmetic.add(reasoning, buckets.reasoning)
            samples.append(sample)
            self.truncated = self.truncated || truncated
        }

        var finalized: FleetUsageEntry {
            let cost = ModelPricingCatalog.estimate(
                samples: samples,
                quotaProviderID: quotaProviderID,
                deepseekPeakWindow: .defaultWindow
            )
            return FleetUsageEntry(
                clientID: key.clientID,
                quotaProviderID: key.quotaProviderID,
                modelName: key.modelName,
                input: input,
                cacheRead: cacheRead,
                output: output,
                reasoning: reasoning,
                value: cost.value,
                currency: cost.currency,
                coverage: FleetCostCoverage(
                    priced: cost.hasPrice,
                    fullyPriced: cost.coverage == .fullyPriced,
                    complete: !truncated
                ),
                truncated: truncated
            )
        }
    }
}
