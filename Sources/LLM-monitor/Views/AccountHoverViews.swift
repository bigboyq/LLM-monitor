import SwiftUI

/// 账号信息：**登录的是哪个账号**、套餐是什么、这些数从哪来。
///
/// 菜单改版删掉 provider 卡的账号折叠区之后，这一块一度没有任何渲染入口（本文件
/// 整体没有调用方），账号从所有 UI 里消失。现在它并到「额度窗口用量」浮层的末尾
/// （`QuotaWindowUsageHoverView.account`）：两个宿主（dock 浮层、菜单兜底行的
/// hover 卡）都在 `ignoresMouseEvents = true` 的 `NSPanel` 里，纯 hover 展不开，
/// 那是这块信息现在唯一可达的路径——与重置卡逐张明细同一个理由。
///
/// 做成**值类型**而不是只留一个视图：调用方（`ProviderCardView`）要能在"这个
/// provider 到底有没有账号可展示"上拿到 nil，测试要能在没有账号数据时断言那段
/// 根本不画。
struct QuotaWindowAccountInfo: Equatable, Sendable {
    let title: String
    let accountEmail: String?
    let planLabel: String?
    let sourceNote: String

    /// 按 provider 给标题与「数据来源」脚注；没有账号概念的 provider 返回 `nil`，
    /// 调用方整段不画（与 `resetCredits` 同一个 nil 容忍模式）。
    ///
    /// GLM / MiniMax 走 API Key，没有"登录的是哪个账号"可写。DeepSeek 虽然有
    /// `balanceDetail`，但 `DeepseekFetcher` 明确不再往 `accountEmail` 里塞任何值
    /// （那是 R7 之前的预格式化余额串），画出来只会永远停在「未拿到账号邮箱」那一行
    /// ——一个永远填不满的占位不如不画。
    static func make(
        providerKind: ProviderKind,
        accountEmail: String?,
        planLabel: String?
    ) -> QuotaWindowAccountInfo? {
        switch providerKind {
        case .antigravity:
            return antigravity(planLabel: planLabel, accountEmail: accountEmail)
        case .codexChatGpt:
            return codex(planLabel: planLabel, accountEmail: accountEmail)
        case .minimaxTokenPlan, .glmCodingPlan, .deepseek:
            return nil
        }
    }

    static func antigravity(planLabel: String?, accountEmail: String?) -> QuotaWindowAccountInfo {
        QuotaWindowAccountInfo(
            title: "Google Antigravity 账号",
            accountEmail: accountEmail,
            planLabel: planLabel,
            sourceNote: "数据来源：本机 Antigravity / agy CLI 的 language_server"
        )
    }

    static func codex(planLabel: String?, accountEmail: String?) -> QuotaWindowAccountInfo {
        QuotaWindowAccountInfo(
            title: "ChatGPT / Codex 账号",
            accountEmail: accountEmail,
            planLabel: planLabel,
            sourceNote: "数据来源：~/.codex/auth.json"
        )
    }
}

/// 账号信息块：标题 + 账号邮箱 + 套餐名 + 数据来源脚注。
///
/// 邮箱为空时只显示提示（缺失字段不显示而不是显示占位符），套餐名为空整行不画。
/// provider 的差异只有标题与脚注，呈现形态完全一致。
struct AccountHoverView: View {
    let info: QuotaWindowAccountInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "person.crop.circle")
                    .foregroundStyle(.secondary)
                Text(info.title)
                    .font(MenuTypography.hoverTitle)
            }

            if let accountEmail = info.accountEmail, !accountEmail.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "envelope")
                        .font(MenuTypography.hoverCaptionEmphasis)
                        .foregroundStyle(.tertiary)
                    Text(accountEmail)
                        .font(MenuTypography.hoverBodyMonospaced)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                }
            } else {
                Text("未拿到账号邮箱（首次刷新后会显示）")
                    .font(MenuTypography.hoverCaption)
                    .foregroundStyle(.tertiary)
            }

            if let planLabel = info.planLabel, !planLabel.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "rosette")
                        .font(MenuTypography.hoverCaptionEmphasis)
                        .foregroundStyle(.tertiary)
                    Text(planLabel)
                        .font(MenuTypography.hoverBody)
                        .foregroundStyle(.secondary)
                }
            }

            Text(info.sourceNote)
                .font(MenuTypography.hoverFootnote)
                .foregroundStyle(.tertiary)
        }
        // 不写死宽度：它现在住在「额度窗口用量」浮层的末尾，那里的宽度由上面的
        // 两栏明细与宿主面板决定。原来独立成 hover 面板时给的 240pt 固定宽度会让
        // 这一段比整块浮层窄一截，被读成另一张卡。
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
