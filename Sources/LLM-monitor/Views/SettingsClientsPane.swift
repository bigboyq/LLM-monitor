import SwiftUI
import AppKit

/// SettingsView 的"客户端"tab：本地客户端用量诊断 + client ↔ quota 绑定开关。
/// 从 SettingsView.swift 拆出（该文件原先 1200+ 行）。

extension SettingsView {
    var clientsPane: some View {
        let clients = sortedClientDescriptors
        // Build every provider projection once for this settings render. The
        // previous implementation recomputed all projections once for the
        // selected panel and once again for every client-count badge.
        let usageByClient = clientProviderUsageByClient()

        return VStack(alignment: .leading, spacing: 16) {
            clientTabBar(clients, usageByClient: usageByClient)

            if let client = clients.first(where: { $0.id == selectedClientID }) {
                let providers = usageByClient[client.id] ?? []
                SettingsSection(
                    title: "已识别的 Provider",
                    footer: providers.isEmpty
                        ? "暂未发现这个客户端产生的本地 Token 数据。使用客户端完成一次模型调用后，重新扫描即可显示。"
                        : "仅显示最近扫描到实际 Token 活动的 Provider。展开行可查看总 Token、缓存命中率和按公开 API 单价估算的价值。"
                ) {
                    if providers.isEmpty {
                        emptyClientState(client)
                    } else {
                        ForEach(providers) { provider in
                            clientProviderDisclosure(provider)
                        }
                    }
                }
            }
        }
        .onAppear {
            if sortedClientDescriptors.contains(where: { $0.id == selectedClientID }) == false {
                selectedClientID = sortedClientDescriptors.first?.id ?? ClientID.antigravity
            }
        }
    }
    var sortedClientDescriptors: [ClientDescriptor] {
        ClientDescriptor.all.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    func clientTabBar(
        _ clients: [ClientDescriptor],
        usageByClient: [String: [ClientProviderUsageSummary]]
    ) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(clients) { client in
                    let selected = selectedClientID == client.id
                    let providerCount = usageByClient[client.id]?.count ?? 0
                    Button {
                        selectedClientID = client.id
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: client.iconSystemName)
                                .font(.system(size: 12, weight: .medium))
                            Text(client.displayName)
                                .font(SettingsTypography.metadata)
                            if providerCount > 0 {
                                Text("\(providerCount)")
                                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(
                                        Capsule(style: .continuous)
                                            .fill(selected ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.12))
                                    )
                            }
                        }
                        .foregroundStyle(selected ? Color.accentColor : .secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            Capsule(style: .continuous)
                                .fill(selected ? Color.accentColor.opacity(0.14) : Color.clear)
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(selected ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.18), lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }

    func clientProviderUsageByClient() -> [String: [ClientProviderUsageSummary]] {
        var rowsByClient: [String: [ClientProviderUsageSummary]] = [:]
        for status in state.statuses {
            let projection = status.usageProjection(for: status.lastSuccess)
            for contribution in projection.contributions {
                guard contribution.hasActivity else { continue }
                if contribution.clientID == ClientID.antigravity, status.kind == .antigravity {
                    rowsByClient[contribution.clientID, default: []].append(
                        contentsOf: antigravityUsageRows(status: status, contribution: contribution)
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
                            deepseekPeakWindow: status.deepseekPeakWindow ?? .defaultWindow
                        )
                    )
                }
            }
        }
        return rowsByClient.mapValues { rows in
            rows.sorted {
                if $0.providerName != $1.providerName {
                    return $0.providerName.localizedCaseInsensitiveCompare($1.providerName) == .orderedAscending
                }
                return $0.usageGroupID < $1.usageGroupID
            }
        }
    }

    /// Antigravity owns one quota account but can produce several billable model
    /// families. Split the settings rows using the model name recorded in each
    /// local sample so each row gets its own token totals and price estimate.
    func antigravityUsageRows(
        status: ProviderStatus,
        contribution: ClientUsageContribution
    ) -> [ClientProviderUsageSummary] {
        let groups: [AntigravityUsageGroup: [LocalTokenUsageSample]]
        if contribution.recentSamples.isEmpty {
            groups = [.other: []]
        } else {
            groups = Dictionary(grouping: contribution.recentSamples) {
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

    func dailyUsage(
        for samples: [LocalTokenUsageSample],
        matching template: [UnifiedDailyTokenUsage]
    ) -> [UnifiedDailyTokenUsage] {
        let calendar = Calendar.current
        var byDay = Dictionary(
            uniqueKeysWithValues: template.map { day in
                (calendar.startOfDay(for: day.dayStart), UnifiedDailyTokenUsage(dayStart: day.dayStart))
            }
        )

        for usage in UnifiedTokenUsageAggregator.days(from: samples, calendar: calendar) {
            let dayStart = calendar.startOfDay(for: usage.dayStart)
            byDay[dayStart] = byDay[dayStart].map { $0 + usage } ?? usage
        }
        return byDay.values.sorted { $0.dayStart < $1.dayStart }
    }

    func emptyClientState(_ client: ClientDescriptor) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: client.iconSystemName)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.tertiary)
            Text("尚未识别到 \(client.displayName) 的 Token 用量")
                .font(SettingsTypography.rowEmphasis)
            Text(client.subtitle)
                .font(SettingsTypography.metadata)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
    }

    func clientProviderDisclosure(_ provider: ClientProviderUsageSummary) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                SevenDayTokenUsageHoverView(
                    days: provider.dailyTokenUsage,
                    scannedAt: provider.scannedAt,
                    isScanning: false,
                    priceByDay: provider.priceTextByDay
                )

                // 第 1 行：聚合指标（总 Token / 命中率 / 价值），放在一起做整体评估。
                HStack(alignment: .top, spacing: 16) {
                    usageMetric(label: "总 Token", value: Formatters.formatTokenCountCompact(provider.totalTokens))
                    usageMetric(label: "命中率", value: provider.cacheHitRate.map { String(format: "%.1f%%", $0 * 100) } ?? "—")
                    usageMetric(label: "价值", value: costText(provider.costEstimate))
                }

                // 第 2 行：分项 Token 桶，让 cache / output / reason 的相对比例一眼可读。
                HStack(alignment: .top, spacing: 16) {
                    usageMetric(label: "Input", value: Formatters.formatTokenCountCompact(provider.inputTokens))
                    usageMetric(label: "Cache", value: Formatters.formatTokenCountCompact(provider.cacheReadTokens))
                    usageMetric(label: "Output", value: Formatters.formatTokenCountCompact(provider.outputTokens))
                    usageMetric(label: "Reason", value: Formatters.formatTokenCountCompact(provider.reasoningTokens))
                }

                if provider.unpricedModelUsage.isEmpty == false {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("未定价模型")
                            .font(SettingsTypography.metadata)
                            .foregroundStyle(.orange)
                        ForEach(provider.unpricedModelUsage) { model in
                            Text("\(model.modelName) · \(Formatters.formatTokenCountCompact(model.totalTokens)) tokens · \(model.sampleCount) 次")
                                .font(SettingsTypography.metadata)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                if provider.costEstimate.pricedModelNames.isEmpty == false {
                    Text("计价模型：\(provider.costEstimate.pricedModelNames.joined(separator: ", ")) · 价格目录更新于 \(ModelPricingCatalog.lastUpdated)")
                        .font(SettingsTypography.metadata)
                        .foregroundStyle(.tertiary)
                }
                if let scannedAt = provider.scannedAt {
                    Text("最近扫描：\(Formatters.formatAbsolute(scannedAt))")
                        .font(SettingsTypography.metadata)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 6))
                    .foregroundStyle(Color.accentColor)
                Text(provider.providerName)
                    .font(SettingsTypography.rowEmphasis)
                Spacer()
                Text(Formatters.formatTokenCountCompact(provider.totalTokens) + " tokens")
                    .font(SettingsTypography.numericValue)
                    .foregroundStyle(.secondary)
            }
        }
        .font(SettingsTypography.metadata)
    }

    func usageMetric(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(SettingsTypography.metadata)
                .foregroundStyle(.secondary)
            Text(value)
                .font(SettingsTypography.numericValue)
        }
    }

    func costText(_ estimate: ModelCostEstimate) -> String {
        // 设置页保留未定价模型明细（unpricedModelUsage），金额文案与菜单共用
        // displayText 的覆盖度语义。
        estimate.displayText
    }

}
