import SwiftUI

/// 账号信息：**登录的是哪个账号**、账号级别是什么。
///
/// 这一块的呈现形态换过三次：菜单 provider 卡的账号折叠区 → 「额度窗口用量」
/// hover 浮层的末尾段（`AccountHoverView`，已随该浮层一并删除）→ 现在的
/// **卡片第一段「Account Info」行**（`ProviderCardView.dockBody` 的段1）。
/// 折叠区与浮层两代都依赖 hover 展开，而两个宿主（dock 浮层、菜单兜底行的
/// hover 卡）都在 `ignoresMouseEvents = true` 的面板里，纯 hover 展不开——
/// 常驻的一行才是唯一永远可达的形态。
///
/// 做成**值类型**而不是只留一个视图：调用方（`ProviderCardView`）要能在"这个
/// provider 到底有没有账号可展示"上拿到 nil，测试要能在没有账号数据时断言
/// 那一行根本不画。`make` 是账号行可见性的**唯一判定来源**。
struct QuotaWindowAccountInfo: Equatable, Sendable {
    /// 账号名（邮箱）。`nil` = 该 provider 拿不到 / 本次刷新还没拿到。
    let accountEmail: String?
    /// 账号级别（套餐档位）。`nil` = 不可得。
    let planLabel: String?

    /// 按 provider 判定这一行画什么；没有可展示内容的 provider 返回 `nil`，
    /// 调用方整行不画。可见性规则（产品决定）：**有真实账号名或真实级别其一
    /// 即显示该行，有啥显示啥；两者皆无整行不画**。
    ///
    /// - codexChatGPT / antigravity：邮箱 + 套餐。antigravity 沿用
    ///   `QuotaSummary.planPillLabel` 的前缀剥离（`Google AI Pro` → `AI Pro`，
    ///   与它曾经在 header 里那颗 pill 同一套文案）。
    /// - glmCodingPlan：API Key 登录、没有邮箱，但 `planLabel` 是套餐档位
    ///   （Lite / Pro / Max，见 `GlmCodingPlanFetcher`）——**仅等级也显示**。
    /// - deepseek：`planLabel` 是余额串（`¥xx.xx`，见 `DeepseekFetcher`），
    ///   **不是账号级别** → 视为不可得，整行不画；余额仍由 `DeepseekBalanceRow`
    ///   在额度区里展示，这里再画一遍就是同一屏两份余额。
    /// - minimaxTokenPlan：两者皆不可得 → 整行不画。
    static func make(
        providerKind: ProviderKind,
        accountEmail: String?,
        planLabel: String?
    ) -> QuotaWindowAccountInfo? {
        let email = nonEmpty(accountEmail)
        let plan = nonEmpty(planLabel)
        switch providerKind {
        case .antigravity, .codexChatGpt:
            let pill = QuotaSummary.planPillLabel(providerKind: providerKind, planLabel: plan)
            if email == nil && pill == nil { return nil }
            return QuotaWindowAccountInfo(accountEmail: email, planLabel: pill)
        case .glmCodingPlan:
            guard let plan else { return nil }
            return QuotaWindowAccountInfo(accountEmail: nil, planLabel: plan)
        case .deepseek, .minimaxTokenPlan:
            return nil
        }
    }

    /// 空串 / 纯空白按不可得处理——首次刷新前的空字段不该把整行"点亮"。
    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// 段1「Account Info」行：账号名 + 账号级别 pill，**一行、不加段落标题**。
///
/// pill 的样式就是它曾经住在 header 里那颗（`MenuTypography.pill` + 次要色 +
/// 胶囊底）：从 header 挪进来的是同一颗 pill，不该换一套皮肤。邮箱用等宽字体，
/// 与它在旧账号浮层里（`AccountHoverView`）的呈现一致。
///
/// 只渲染拿得到的字段（`make` 已保证至少有一个）：邮箱缺失时不画占位符——
/// 旧的「未拿到账号邮箱（首次刷新后会显示）」是浮层里的说明文案，常驻行里
/// 一句永远悬着的占位只会变成噪音。
struct QuotaWindowAccountInfoRow: View {
    let info: QuotaWindowAccountInfo

    var body: some View {
        HStack(spacing: 6) {
            if let email = info.accountEmail {
                Text(email)
                    .font(MenuTypography.hoverBodyMonospaced)
                    .foregroundStyle(Color.primaryLabel)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(email)
            }
            if let plan = info.planLabel {
                Text(plan)
                    .font(MenuTypography.pill)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.06), in: Capsule())
            }
        }
    }
}
