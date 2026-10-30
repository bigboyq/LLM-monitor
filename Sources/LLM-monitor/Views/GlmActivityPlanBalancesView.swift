import SwiftUI

/// GLM 活动套餐（zcode-plan，如周末体验套餐）余额展示行。
///
/// 数据来自 `GlmZcodeAPIClient` 直连接口获取的 ZCode 活动套餐与额度重置卡（设置
/// `parseZcodePlan` 开启后采集）。
/// 布局与 OpenAI API 赠金行 / Google Argon 保持同等规格：
/// - 有套餐或重置卡就显示，两者均无整块不渲染；
/// - 生效中套餐（`balances`）：正常显示卡片主题色，渲染独立进度条、剩余/总量 token 与失效倒计时（剩余X小时），<=2h 黄色预警，<=1h 红色告警；
/// - 未生效套餐（`previews`）：整块灰色弱化显示，进度条置灰底，显示生效倒计时（X小时后生效），标注「额度：Z」；
/// - 额度重置卡（`resetCards`）：双列展示 5 小时卡与周卡，最多展示前 3 张，无卡显示暂无可用卡。
struct GlmActivityPlanBalancesView: View {
    let balances: [GlmActivityPlanBalance]?
    /// 生效前预告行；默认空，保持既有 `init(balances:)` 调用可编译。
    var previews: [GlmActivityPlanPreview] = []
    /// 额度重置卡快照（5小时卡与周卡）
    var resetCards: GlmResetCardsSnapshot? = nil
    /// 卡片主题色，默认 GLM 品牌色
    var tint: Color = .glmBrand

    @Environment(\.displayDate) private var displayDate

    var body: some View {
        let visible = balances ?? []
        let hasBalances = !visible.isEmpty || !previews.isEmpty
        let hasResetCards = (resetCards?.totalCardCount ?? 0) > 0

        if hasBalances || hasResetCards {
            VStack(alignment: .leading, spacing: 6) {
                if hasBalances {
                    Divider().opacity(0.3)
                    ForEach(visible, id: \.entitlementID) { balance in
                        activeBlock(for: balance)
                    }
                    ForEach(previews, id: \.entitlementID) { preview in
                        previewBlock(for: preview)
                    }
                }
                if let resetCards, hasResetCards {
                    Divider().opacity(0.3)
                    resetCardsBlock(for: resetCards)
                }
            }
        }
    }

    // MARK: - 额度重置卡（Reset Cards）

    @ViewBuilder
    private func resetCardsBlock(for snapshot: GlmResetCardsSnapshot) -> some View {
        HStack(alignment: .top, spacing: 12) {
            resetCardColumn(
                title: "5小时重置卡 (\(snapshot.fiveHourResets.count))",
                cards: snapshot.fiveHourResets
            )
            .frame(maxWidth: .infinity, alignment: .leading)

            resetCardColumn(
                title: "周重置卡 (\(snapshot.weekResets.count))",
                cards: snapshot.weekResets
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func resetCardColumn(title: String, cards: [GlmResetCardItem]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.counterclockwise.circle")
                    .font(MenuTypography.badge)
                    .foregroundStyle(tint)
                Text(title)
                    .font(MenuTypography.hoverRowEmphasis)
                    .foregroundStyle(Color.primaryLabel)
                    .lineLimit(1)
            }

            let shownCards = Array(cards.prefix(3))
            if shownCards.isEmpty {
                Text("暂无可用卡")
                    .font(MenuTypography.resetDate)
                    .foregroundStyle(Color.secondaryLabel)
                    .lineLimit(1)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(shownCards.enumerated()), id: \.offset) { _, card in
                        Text("\(Formatters.formatMonthDayMinute(card.expireAt)) 到期")
                            .font(MenuTypography.resetDate)
                            .foregroundStyle(Color.secondaryLabel)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    // MARK: - 生效中套餐（Active Balance）

    @ViewBuilder
    private func activeBlock(for balance: GlmActivityPlanBalance) -> some View {
        let percentFraction = balance.totalUnits > 0
            ? min(max(Double(balance.remainingUnits) / Double(balance.totalUnits), 0.0), 1.0)
            : 0.0
        let percentText = remainingPercent(balance)
        let used = Formatters.formatTokenCountCompact(balance.usedUnits)
        let remaining = Formatters.formatTokenCountCompact(balance.remainingUnits)
        let total = Formatters.formatTokenCountCompact(balance.totalUnits)
        let expiryColor = Self.expiryColor(for: balance.expiresAt, now: displayDate)

        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "gift.fill")
                        .font(MenuTypography.badge)
                        .foregroundStyle(tint)
                    Text(Self.displayTitle(
                        planName: balance.planName,
                        showName: balance.showName,
                        entitlementID: balance.entitlementID
                    ))
                    .font(MenuTypography.hoverRowEmphasis)
                    .foregroundStyle(Color.primaryLabel)
                    .lineLimit(1)
                }

                Spacer(minLength: 4)

                Text("活动套餐")
                    .font(MenuTypography.dataLabel)
                    .foregroundStyle(Color.secondaryLabel)
                    .lineLimit(1)
            }

            SegmentedQuotaProgressBar(
                primaryFraction: percentFraction,
                weeklyFraction: percentFraction,
                tint: tint,
                segments: 1,
                height: 8,
                timeRemainingFraction: nil
            )
            .frame(maxWidth: .infinity)

            HStack(spacing: 6) {
                Text("已用 \(used) · 剩余：\(remaining)/\(total) (\(percentText))")
                    .font(MenuTypography.dataValue)
                    .foregroundStyle(Color.secondaryLabel)
                    .lineLimit(1)

                Spacer(minLength: 6)

                if let expiresAt = balance.expiresAt {
                    let countdown = Self.formatExpiryCountdown(from: expiresAt, now: displayDate)
                    HStack(spacing: 3) {
                        if expiryColor != Color.secondaryLabel {
                            Image(systemName: "clock.badge.exclamationmark")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(expiryColor)
                        }
                        Text("失效时间：\(Formatters.formatMonthDayMinute(expiresAt))（\(countdown)）")
                            .font(MenuTypography.resetDate)
                            .foregroundStyle(expiryColor)
                            .lineLimit(1)
                    }
                } else {
                    Text("失效时间未知")
                        .font(MenuTypography.resetDate)
                        .foregroundStyle(Color.secondaryLabel)
                        .lineLimit(1)
                }
            }
            .minimumScaleFactor(0.85)
        }
    }

    // MARK: - 未生效套餐（Preview）

    @ViewBuilder
    private func previewBlock(for preview: GlmActivityPlanPreview) -> some View {
        let grant = Formatters.formatTokenCountCompact(preview.grantUnits)
        let countdown = Self.formatEffectiveCountdown(from: preview.effectiveAt, now: displayDate)

        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "gift")
                        .font(MenuTypography.badge)
                    Text(Self.displayTitle(
                        planName: preview.planName,
                        showName: preview.showName,
                        entitlementID: preview.entitlementID
                    ))
                    .font(MenuTypography.hoverRowEmphasis)
                    .lineLimit(1)
                    Text("未生效")
                        .font(MenuTypography.hint)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.primary.opacity(0.06))
                        )
                }
                .foregroundStyle(Color.secondaryLabel)

                Spacer(minLength: 4)

                Text("活动套餐")
                    .font(MenuTypography.dataLabel)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            SegmentedQuotaProgressBar(
                primaryFraction: 0,
                weeklyFraction: 0,
                tint: Color.secondary.opacity(0.35),
                segments: 1,
                height: 8,
                timeRemainingFraction: nil
            )
            .frame(maxWidth: .infinity)

            HStack(spacing: 6) {
                Text("额度：\(grant)")
                    .font(MenuTypography.dataValue)
                    .foregroundStyle(Color.secondaryLabel)
                    .lineLimit(1)

                Spacer(minLength: 6)

                Text("生效时间：\(Formatters.formatMonthDayMinute(preview.effectiveAt))（\(countdown)）")
                    .font(MenuTypography.resetDate)
                    .foregroundStyle(Color.secondaryLabel)
                    .lineLimit(1)
            }
            .minimumScaleFactor(0.85)
        }
    }

    // MARK: - 纯函数辅助与倒计时计算

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
    static func remainingPercent(_ balance: GlmActivityPlanBalance) -> String {
        guard balance.totalUnits > 0 else { return "--" }
        let percent = Double(balance.remainingUnits) / Double(balance.totalUnits) * 100
        return Formatters.formatQuotaPercent(percent)
    }

    private func remainingPercent(_ balance: GlmActivityPlanBalance) -> String {
        Self.remainingPercent(balance)
    }

    /// 生效倒计时：例如 `2小时后生效`、`30分后生效`、`1天2小时后生效`
    static func formatEffectiveCountdown(from effectiveAt: Date, now: Date) -> String {
        let delta = effectiveAt.timeIntervalSince(now)
        guard delta > 0 else { return "已生效" }
        let total = Int(delta.rounded())
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        if days > 0 {
            return hours > 0 ? "\(days)天\(hours)小时后生效" : "\(days)天后生效"
        } else if hours > 0 {
            return minutes > 0 ? "\(hours)小时\(minutes)分后生效" : "\(hours)小时后生效"
        } else {
            return "\(max(minutes, 1))分后生效"
        }
    }

    /// 失效倒计时：例如 `剩余12小时`、`剩余30分`、`剩余1天2小时`
    static func formatExpiryCountdown(from expiresAt: Date, now: Date) -> String {
        let delta = expiresAt.timeIntervalSince(now)
        guard delta > 0 else { return "已失效" }
        let total = Int(delta.rounded())
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        if days > 0 {
            return hours > 0 ? "剩余\(days)天\(hours)小时" : "剩余\(days)天"
        } else if hours > 0 {
            return minutes > 0 ? "剩余\(hours)小时\(minutes)分" : "剩余\(hours)小时"
        } else {
            return "剩余\(max(minutes, 1))分"
        }
    }

    /// 到期紧迫度颜色：<=1h 红色、<=2h 黄色、>2h 正常（次要灰）
    static func expiryColor(for expiresAt: Date?, now: Date) -> Color {
        guard let expiresAt else { return Color.secondaryLabel }
        let remaining = expiresAt.timeIntervalSince(now)
        if remaining <= 3600 {
            return Color.criticalTint
        } else if remaining <= 2 * 3600 {
            return Color.warningTint
        } else {
            return Color.secondaryLabel
        }
    }
}
