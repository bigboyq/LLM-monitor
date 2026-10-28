import Foundation

// MARK: - 报告构建（§6.3）

/// 副节点报告的构建输入：身份、配置与当前 UI 同源的状态快照。
struct UsageReportInput {
    let nodeID: UUID
    let nodeName: String
    let bindings: [ClientProviderBinding]
    let statuses: [ProviderStatus]
    var now: Date = Date()
    var calendar: Calendar = .current

    init(
        nodeID: UUID,
        nodeName: String,
        bindings: [ClientProviderBinding],
        statuses: [ProviderStatus],
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
        self.nodeID = nodeID
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
/// seq 由 `FleetStore.allocateLocalSeq()` 在发送前持久化分配，这里只填充。
enum UsageReportBuilder {
    static func build(_ input: UsageReportInput, seq: Int) -> NodeUsageReport {
        var entryRows: [EntryKey: EntryAccumulator] = [:]
        var clientDayRows: [ClientDayKey: FleetClientProviderUsage] = [:]
        var unavailableSourcesByKey: [String: FleetDailyUnavailableSource] = [:]
        var anySampleDetailsIncomplete = false

        // 每个 provider 的 L2 投影只算一次：日桶通道与窗口通道共用同一份。
        // 原来两条通道各算一遍 —— 主线程上白跑一次全量投影（帧抽取 + 日聚合
        // + 当日 max 修补），而报告构建发生在每次状态变化的防抖之后。
        var projections: [ProviderKind: ProviderUsageProjection] = [:]
        for status in input.statuses {
            // 用量通道也尊重 isEnabled：用户在 config 里禁用的 provider 仍会
            // 保留扫描缓存（LocalUsageOrchestration 的约定），那些缓存不该
            // 被上报并计入 hub 的权威合计。额度通道本来就有这道门控（§5.1），
            // 同一份报告里两套口径会自相矛盾。
            guard status.isEnabled else { continue }
            projections[status.kind] = status.usageProjection(for: status.lastSuccess, now: input.now)
        }

        for status in input.statuses {
            guard status.isEnabled else { continue }
            guard let projection = projections[status.kind] else { continue }
            let quotaProviderID = status.kind.quotaProviderID

            // Freshness is stored per scanner source, while this legacy flag has
            // provider scope. Conservatively apply the flag only to sources this
            // status actually consumes, and keep precise failed/scanning states.
            for consumer in status.localUsageConsumers {
                let sourceFreshness = status.localUsageFreshness[consumer.source]
                let reason: FleetDailyUnavailableReason?
                switch sourceFreshness {
                case .failed:
                    reason = .failed
                case .scanning:
                    reason = .scanning
                case .clean, .dirty:
                    reason = status.isScanningLocalUsage ? .scanning : nil
                }
                if let reason {
                    Self.markUnavailable(consumer, reason: reason, in: &unavailableSourcesByKey)
                }
            }

            // DSH's scan budget can truncate the source even when no retained
            // provider frame exists. Do not let that empty projection look like
            // a verified zero, and do not let it affect unrelated consumers.
            if status.dshUsage?.isTruncated == true,
               let dshConsumer = status.localUsageConsumers.first(where: { $0.source == .dsh }) {
                Self.markUnavailable(dshConsumer, reason: .truncated, in: &unavailableSourcesByKey)
            }

            for contribution in projection.contributions {
                let key = "\(contribution.clientID)|\(quotaProviderID)"
                if contribution.isTruncated,
                   status.localUsageConsumers.contains(where: { $0.sourceKey == key }) {
                    Self.markUnavailable(
                        clientID: contribution.clientID,
                        quotaProviderID: quotaProviderID,
                        reason: .truncated,
                        in: &unavailableSourcesByKey
                    )
                }
            }
        }

        for status in input.statuses {
            guard status.isEnabled else { continue }
            guard let projection = projections[status.kind] else { continue }
            let quotaProviderID = status.kind.quotaProviderID

            for contribution in projection.contributions {
                let sourceKey = "\(contribution.clientID)|\(quotaProviderID)"
                if unavailableSourcesByKey[sourceKey] != nil { continue }
                if contribution.samplesTruncated { anySampleDetailsIncomplete = true }

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
                        .add(
                            sample: sample,
                            truncated: contribution.samplesTruncated
                        )
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
            let unavailableSources = unavailableSourcesByKey.values.sorted {
                ($0.clientID, $0.quotaProviderID) < ($1.clientID, $1.quotaProviderID)
            }
            buckets.append(FleetDailyBucket(
                dayKey: dayKey,
                totals: totals,
                clientProviders: clientRows,
                entries: entries,
                totalsComplete: unavailableSources.isEmpty,
                modelDetailsComplete: unavailableSources.isEmpty && !anySampleDetailsIncomplete,
                sourceTruncated: unavailableSources.contains { $0.reason == .truncated },
                unavailableSources: unavailableSources.isEmpty ? nil : unavailableSources
            ))
        }

        let windowRows: [FleetWindowUsage] = input.statuses.flatMap { status -> [FleetWindowUsage] in
            guard let projection = projections[status.kind] else { return [] }
            return buildWindowRows(status: status, projection: projection, now: input.now)
        }
        let quotaReports = input.statuses.compactMap { status -> FleetQuotaReport? in
            guard status.isEnabled, let info = status.lastSuccess else { return nil }
            let report = quotaReport(status: status, info: info)
            return report.hasActiveQuotaWindow ? report : nil
        }

        // Failed/scanning sources are carried in daily buckets as source markers so
        // healthy clients still contribute. Window rows remain omitted for unavailable
        // provider scopes; an empty window array preserves the hub's last-known values.
        return NodeUsageReport(
            protocolVersion: FleetProtocol.version,
            node: FleetNodeIdentity(
                nodeID: input.nodeID,
                nodeName: input.nodeName,
                timezoneID: TimeZone.current.identifier,
                platform: "macOS"
            ),
            seq: seq,
            generatedAt: input.now,
            attributionFingerprint: FleetAttributionFingerprint.compute(input.bindings),
            dailyBuckets: buckets,
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
    static func buildWindowRows(
        status: ProviderStatus,
        projection: ProviderUsageProjection,
        now: Date
    ) -> [FleetWindowUsage] {
        // 同日桶通道：禁用 provider 的窗口摘要不上报。
        guard status.isEnabled else { return [] }
        // 空 projection 可能是失败/扫描中的本地账本，而非真实零用量。
        // 省略这些 provider 的窗口行，让 hub 保留相同边界上的最后有效摘要。
        guard !localUsageUnavailable(status) else { return [] }
        guard let info = status.lastSuccess else { return [] }
        let quotaProviderID = status.kind.quotaProviderID
        let samples = projection.recentSamples
        let truncated = projection.isTruncated || projection.samplesTruncated
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
                    truncated: truncated,
                    quotaProviderIDForPricing: quotaProviderID,
                    peakWindow: peakWindow
                ) else { continue }
                rows.append(row)
            }

            // 「免 / 速 / 它」今日切片（Start Plan / 加速卡 / 其他智谱任务）：与
            // 本地卡动态行（`ProviderCardDerivedValues.glmCategoryUsageRows`）
            // 同源同口径——同一份 `glmCategoryTodaySamples` 切片谓词。窗口边界取
            // 报告时刻所在自然日 `[startOfDay, +1d)`：各 GLM 节点同日同时区则边界
            // 完全一致，hub 的窗口聚合只合并边界相同的行，同边界键才不会把当日
            // 无用量的节点误标 missing。当日无样本的分类照常上报全零行（展示层
            // `visibleRows` 统一跳过全零行，与本地卡同一机制）。
            let calendar = Calendar.current
            let todayStart = calendar.startOfDay(for: now)
            if let todayEnd = calendar.date(byAdding: .day, value: 1, to: todayStart),
               let quotaModelName = info.activeModels.first?.modelName {
                let glms: [(windowKind: String, category: GlmUsageCategory)] = [
                    ("glmStartPlan", .startPlan),
                    ("glmHighspeed", .highSpeed),
                    ("glmOtherPlan", .other),
                ]
                for glm in glms {
                    let matched = LocalUsageSummaryBuilder.glmCategoryTodaySamples(
                        samples: samples,
                        providerKind: status.kind,
                        quotaModelName: quotaModelName,
                        category: glm.category,
                        offPeakWindows: status.glmOffPeakWindows,
                        now: now,
                        calendar: calendar
                    )
                    if let row = windowUsageRow(
                        quotaProviderID: quotaProviderID,
                        modelID: quotaModelName,
                        windowKind: glm.windowKind,
                        bounds: LocalUsageWindowBounds(start: todayStart, end: todayEnd),
                        samples: matched,
                        truncated: truncated,
                        quotaProviderIDForPricing: quotaProviderID,
                        peakWindow: peakWindow
                    ) {
                        rows.append(row)
                    }
                }
            }
        }
        return rows
    }

    private static func localUsageUnavailable(_ status: ProviderStatus) -> Bool {
        let freshness = status.effectiveLocalUsageFreshness
        return status.isScanningLocalUsage || freshness == .scanning || freshness == .failed
    }

    private static func markUnavailable(
        _ consumer: LocalUsageConsumer,
        reason: FleetDailyUnavailableReason,
        in sources: inout [String: FleetDailyUnavailableSource]
    ) {
        markUnavailable(
            clientID: consumer.clientID,
            quotaProviderID: consumer.quotaProviderID,
            reason: reason,
            in: &sources
        )
    }

    private static func markUnavailable(
        clientID: String,
        quotaProviderID: String,
        reason: FleetDailyUnavailableReason,
        in sources: inout [String: FleetDailyUnavailableSource]
    ) {
        let marker = FleetDailyUnavailableSource(
            clientID: clientID,
            quotaProviderID: quotaProviderID,
            reason: reason
        )
        // Failure/scanning is more informative than truncation when a source is
        // simultaneously stale and budget-limited.
        if let existing = sources[marker.sourceKey], existing.severity >= marker.severity {
            return
        }
        sources[marker.sourceKey] = marker
    }

    private static func windowUsageRow(
        quotaProviderID: String,
        modelID: String,
        windowKind: String,
        bounds: LocalUsageWindowBounds,
        samples: [LocalTokenUsageSample],
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
