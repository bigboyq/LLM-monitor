import Foundation

/// 「client → Provider 用量行」聚合的共享实现：设置页"客户端"tab 与后续
/// Harness（客户端视角）菜单视图共用同一口径，避免两处各算一套。
///
/// 从 `SettingsView`（原 SettingsClientsPane.swift）提取成纯函数：输入
/// `[ProviderStatus]`（调用方传 `state.statuses`），不再依赖任何视图实例状态。
/// 提取是无损搬移——回归护栏为 `SettingsClientsPaneTests`（ZCode 行序断言在
/// 那里）与 `UIUsageRegressionTests.testSettingsGroupingUsesOnlySevenDisplayedDays`。
enum ClientUsageAggregation {
    /// 按 client 分组的 Provider 用量行。`clientProviderUsageByClient(for:)`
    /// 输出的每个 client 列内行序固定（见 `zcodeRowRank`），调用方不再排序。
    static func clientProviderUsageByClient(
        for statuses: [ProviderStatus]
    ) -> [String: [ClientProviderUsageSummary]] {
        var rowsByClient: [String: [ClientProviderUsageSummary]] = [:]
        for status in statuses {
            let projection = status.usageProjection(for: status.lastSuccess)
            for contribution in projection.contributions {
                guard contribution.hasActivity else { continue }
                if contribution.clientID == ClientID.antigravity, status.kind == .antigravity {
                    rowsByClient[contribution.clientID, default: []].append(
                        contentsOf: antigravityUsageRows(status: status, contribution: contribution)
                    )
                } else if contribution.clientID == ClientID.zcode, status.kind == .glmCodingPlan,
                          !contribution.recentSamples.isEmpty {
                    rowsByClient[contribution.clientID, default: []].append(
                        contentsOf: glmUsageRows(status: status, contribution: contribution)
                    )
                } else {
                    rowsByClient[contribution.clientID, default: []].append(
                        ClientProviderUsageSummary(
                            clientID: contribution.clientID,
                            quotaProviderID: status.kind.quotaProviderID,
                            providerName: status.displayName,
                            usageGroupID: status.kind.quotaProviderID,
                            dailyTokenUsage: contribution.dailyTokenUsage,
                            recentSamples: contribution.recentSamples,
                            scannedAt: contribution.scannedAt,
                            isTruncated: contribution.isTruncated,
                            deepseekPeakWindow: status.deepseekPeakWindow ?? .defaultWindow
                        )
                    )
                }
            }
        }
        return rowsByClient.mapValues { rows in
            rows.sorted { lhs, rhs in
                // ZCode 客户端区是唯一混排多种语义行的列：GLM 分类行（套餐名）
                // 与 DeepSeek / MiniMax 分片行（provider 名）必须按固定口径排，
                // 字母序会得到 "Coding Plan → DeepSeek → Start Plan → …"。
                if lhs.clientID == ClientID.zcode {
                    let l = zcodeRowRank(lhs), r = zcodeRowRank(rhs)
                    if l != r { return l < r }
                }
                if lhs.providerName != rhs.providerName {
                    return lhs.providerName.localizedCaseInsensitiveCompare(rhs.providerName) == .orderedAscending
                }
                return lhs.usageGroupID < rhs.usageGroupID
            }
        }
    }

    /// ZCode 列的行序：Coding Plan → Start Plan → 闲时任务 → 其他任务 →
    /// DeepSeek → MiniMax。
    ///
    /// GLM 分类行取 `GlmUsageCategory.allCases` 的声明序（枚举加 case 时行序
    /// 自动跟随）；两个分片行来自 MiniMax / DeepSeek 卡的 ZCode 贡献
    /// （`zcodeContribution`，受 `mergeZcodeUsage` 与 `clientBindings` 门控），
    /// 它们不是套餐而是 provider，固定排在分类行之后。
    static func zcodeRowRank(_ row: ClientProviderUsageSummary) -> Int {
        let glmCount = GlmUsageCategory.allCases.count
        if row.quotaProviderID == QuotaProviderID.zhipu,
           let category = GlmUsageCategory(rawValue: row.usageGroupID) {
            return GlmUsageCategory.allCases.firstIndex(of: category) ?? 0
        }
        switch row.quotaProviderID {
        case QuotaProviderID.deepseek: return glmCount
        case QuotaProviderID.minimax: return glmCount + 1
        default: return glmCount + 2
        }
    }

    /// Antigravity owns one quota account but can produce several billable model
    /// families. Split the settings rows using the model name recorded in each
    /// local sample so each row gets its own token totals and price estimate.
    static func antigravityUsageRows(
        status: ProviderStatus,
        contribution: ClientUsageContribution
    ) -> [ClientProviderUsageSummary] {
        // OpenCode/native recent samples can span eight days while the
        // settings chart is deliberately padded to seven calendar days.  Do
        // the windowing before classifying samples; otherwise an out-of-window
        // model can create a phantom group (and its cost estimate).
        let displayedSamples = samplesInDisplayedWindow(
            contribution.recentSamples,
            matching: contribution.dailyTokenUsage
        )
        let groups: [AntigravityUsageGroup: [LocalTokenUsageSample]]
        if displayedSamples.isEmpty {
            let hasDisplayedDailyActivity = contribution.dailyTokenUsage.contains {
                $0.totalTokens > 0 || $0.turns > 0 || $0.rounds > 0
            }
            groups = hasDisplayedDailyActivity ? [.other: []] : [:]
        } else {
            groups = Dictionary(grouping: displayedSamples) {
                AntigravityUsageGroup.classify(modelName: $0.modelName)
            }
        }

        return groups.keys.sorted {
            let comparison = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            return $0.rawValue < $1.rawValue
        }.map { group in
            let samples = groups[group] ?? []
            let daily = samples.isEmpty
                ? contribution.dailyTokenUsage
                : dailyUsage(for: samples, matching: contribution.dailyTokenUsage)
            return ClientProviderUsageSummary(
                clientID: ClientID.antigravity,
                quotaProviderID: status.kind.quotaProviderID,
                providerName: group.displayName,
                usageGroupID: group.rawValue,
                dailyTokenUsage: daily,
                recentSamples: samples,
                scannedAt: contribution.scannedAt,
                deepseekPeakWindow: status.deepseekPeakWindow ?? .defaultWindow
            )
        }
    }

    /// ZCode 一次扫描覆盖智谱系全部 provider 任务（Coding Plan / Start Plan /
    /// 闲时 / 其他智谱套餐）。按样本上的 `sourceProviderID` 分类拆行，各自独立
    /// token 柱图与计价——对齐 Antigravity 按模型分组拆行的模式；弹窗卡片维持
    /// 合并汇总不拆。空分类不出现（"如有"语义由 `allCases` + 非空判定给出）。
    /// 样本为空（旧缓存 / 无样本）时保持整行不拆，避免把聚合值错标成某一分类。
    static func glmUsageRows(
        status: ProviderStatus,
        contribution: ClientUsageContribution
    ) -> [ClientProviderUsageSummary] {
        let displayedSamples = samplesInDisplayedWindow(
            contribution.recentSamples,
            matching: contribution.dailyTokenUsage
        )
        let groups = Dictionary(grouping: displayedSamples) {
            GlmUsageCategory.classify($0)
        }
        return GlmUsageCategory.allCases.compactMap { category in
            guard let samples = groups[category], !samples.isEmpty else { return nil }
            return ClientProviderUsageSummary(
                clientID: ClientID.zcode,
                quotaProviderID: status.kind.quotaProviderID,
                providerName: category.displayName,
                usageGroupID: category.rawValue,
                dailyTokenUsage: dailyUsage(for: samples, matching: contribution.dailyTokenUsage),
                recentSamples: samples,
                scannedAt: contribution.scannedAt,
                deepseekPeakWindow: status.deepseekPeakWindow ?? .defaultWindow
            )
        }
    }

    static func dailyUsage(
        for samples: [LocalTokenUsageSample],
        matching template: [UnifiedDailyTokenUsage]
    ) -> [UnifiedDailyTokenUsage] {
        let calendar = Calendar.current
        var byDay = Dictionary(
            uniqueKeysWithValues: template.map { day in
                (calendar.startOfDay(for: day.dayStart), UnifiedDailyTokenUsage(dayStart: day.dayStart))
            }
        )

        // `recentSamples` intentionally keeps one extra day for quota-window
        // calculations.  The settings chart, however, is keyed by the seven
        // days in `template`; do not let that extra day grow the chart or its
        // grouped totals.
        let displayedSamples = samplesInDisplayedWindow(samples, matching: template)
        for usage in UnifiedTokenUsageAggregator.days(from: displayedSamples, calendar: calendar) {
            let dayStart = calendar.startOfDay(for: usage.dayStart)
            byDay[dayStart] = byDay[dayStart].map { $0 + usage } ?? usage
        }
        return byDay.values.sorted { $0.dayStart < $1.dayStart }
    }

    private static func samplesInDisplayedWindow(
        _ samples: [LocalTokenUsageSample],
        matching dailyUsage: [UnifiedDailyTokenUsage]
    ) -> [LocalTokenUsageSample] {
        // Scanner 的日窗口连续且已补零；按时间边界过滤，避免对每个样本重复换算日历。
        guard let start = dailyUsage.map(\.dayStart).min(),
              let lastDay = dailyUsage.map(\.dayStart).max(),
              let end = Calendar.current.date(byAdding: .day, value: 1, to: lastDay) else { return [] }
        return samples.filter {
            $0.completedAt >= start && $0.completedAt < end
        }
    }
}
