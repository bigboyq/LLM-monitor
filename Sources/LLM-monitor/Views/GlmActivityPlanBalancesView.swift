import SwiftUI

/// GLM 活动套餐（zcode-plan，如周末体验套餐）余额展示行。
///
/// 数据来自 `GlmZcodeBalanceLogReader` 解析的 ZCode 余额轮询日志（设置
/// `parseZcodeBalanceLog` 开启后才采集）。每条 entitlement 一行：
/// `🎁 套餐名  94% (283M/300M)  08-31 09:00`——百分比是剩余占比，括号内是
/// 可用/总量 token，末尾是过期时间。balances 为空（未开启 / 无活动套餐 /
/// 已全部过期）时整块不渲染 —— 与「额度消失就不显示」的口径一致。
struct GlmActivityPlanBalancesView: View {
    let balances: [GlmActivityPlanBalance]?

    var body: some View {
        let visible = balances ?? []
        if !visible.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(visible, id: \.entitlementID) { balance in
                    row(for: balance)
                }
            }
        }
    }

    @ViewBuilder
    private func row(for balance: GlmActivityPlanBalance) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "gift.fill")
                .font(MenuTypography.badge)
            Text(displayTitle(balance))
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

    private func displayTitle(_ balance: GlmActivityPlanBalance) -> String {
        let plan = balance.planName.trimmingCharacters(in: .whitespacesAndNewlines)
        return plan.isEmpty ? balance.showName : plan
    }

    /// 剩余百分比（remaining / total），与额度窗口同一套取整口径。
    private func remainingPercent(_ balance: GlmActivityPlanBalance) -> String {
        guard balance.totalUnits > 0 else { return "--" }
        let percent = Double(balance.remainingUnits) / Double(balance.totalUnits) * 100
        return Formatters.formatQuotaPercent(percent)
    }
}
