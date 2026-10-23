import SwiftUI

/// GLM 活动套餐（zcode-plan，如周末体验套餐）余额展示行。
///
/// 数据来自 `GlmZcodeBalanceLogReader` 解析的 ZCode 余额轮询日志（设置
/// `parseZcodeBalanceLog` 开启后才采集）。每条 entitlement 一行：
/// `🎁 套餐名 · 模型名  94% (283M/300M)  08-31 09:00`——百分比是剩余占比，括号内是
/// 可用/总量 token，末尾是过期时间。额度生效前 balances 为空、entitlements 已下发时，
/// 改渲染预告行（`previewRow`，只报套餐名 · 模型名 + 生效时间 + 授予量）。
/// balances 与 previews 都为空（未开启 / 无活动套餐 / 已全部过期）时整块不渲染
/// —— 与「额度消失就不显示」的口径一致。
struct GlmActivityPlanBalancesView: View {
    let balances: [GlmActivityPlanBalance]?
    /// 生效前预告行；默认空，保持既有 `init(balances:)` 调用可编译。
    var previews: [GlmActivityPlanPreview] = []

    var body: some View {
        let visible = balances ?? []
        if !visible.isEmpty || !previews.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(visible, id: \.entitlementID) { balance in
                    row(for: balance)
                }
                ForEach(previews, id: \.entitlementID) { preview in
                    previewRow(for: preview)
                }
            }
        }
    }

    @ViewBuilder
    private func row(for balance: GlmActivityPlanBalance) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "gift.fill")
                .font(MenuTypography.badge)
            Text(Self.displayTitle(
                planName: balance.planName,
                showName: balance.showName,
                entitlementID: balance.entitlementID
            ))
            .font(MenuTypography.metricLabel)
            .lineLimit(1)
            Text(remainingPercent(balance))
                .font(MenuTypography.metricValue)
            Text("(\(Formatters.formatTokenCountCompact(balance.remainingUnits))/\(Formatters.formatTokenCountCompact(balance.totalUnits)))")
                .font(MenuTypography.metricValue)
            if let expiresAt = balance.expiresAt {
                Text(Formatters.formatMonthDayMinute(expiresAt))
                    .font(MenuTypography.timeSuffix)
                    .foregroundStyle(.tertiary)
            }
        }
        .foregroundStyle(.secondary)
    }

    /// 生效前预告行：额度还没生效，报消耗（百分比 / 已用剩余）没有意义，
    /// 只报套餐名 · 模型名 + 生效时间 + 授予量；整行 `.tertiary` 与余额行区分。
    @ViewBuilder
    private func previewRow(for preview: GlmActivityPlanPreview) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "gift")
                .font(MenuTypography.badge)
            Text(Self.displayTitle(
                planName: preview.planName,
                showName: preview.showName,
                entitlementID: preview.entitlementID
            ))
            .font(MenuTypography.metricLabel)
            .lineLimit(1)
            Text("生效时间：\(Formatters.formatMonthDayMinute(preview.effectiveAt))")
                .font(MenuTypography.timeSuffix)
            Text("（\(Formatters.formatTokenCountCompact(preview.grantUnits))）")
                .font(MenuTypography.metricValue)
        }
        .foregroundStyle(.tertiary)
    }

    /// 行标题：`套餐名 · 展示名`。展示名为空 / 与套餐名忽略大小写相同 / 实为
    /// entitlementID 回退值（即 show_name 缺失被 reader 用 entitlementID 填充）时
    /// 不参与拼接，只显示套餐名。静态纯函数，测试经 `@testable` 直接命中。
    static func displayTitle(planName: String, showName: String, entitlementID: String) -> String {
        let plan = planName.trimmingCharacters(in: .whitespacesAndNewlines)
        let show = showName.trimmingCharacters(in: .whitespacesAndNewlines)
        let showIsDistinct = !show.isEmpty
            && show != entitlementID
            && show.caseInsensitiveCompare(plan) != .orderedSame
        guard !plan.isEmpty else { return show }
        return showIsDistinct ? "\(plan) · \(show)" : plan
    }

    /// 剩余百分比（remaining / total），与额度窗口同一套取整口径。
    private func remainingPercent(_ balance: GlmActivityPlanBalance) -> String {
        guard balance.totalUnits > 0 else { return "--" }
        let percent = Double(balance.remainingUnits) / Double(balance.totalUnits) * 100
        return Formatters.formatQuotaPercent(percent)
    }
}
