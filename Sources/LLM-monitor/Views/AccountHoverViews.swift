import SwiftUI

/// 登录账号 hover 详情（Antigravity / ChatGPT 共用）：标题 + 账号邮箱 + 套餐名。
/// 邮箱为空时只显示提示（缺失字段不显示而不是显示占位符）。
/// provider 差异只有标题文案与"数据来源"脚注，DeepSeek 的余额结构不同，
/// 走独立的 `DeepseekAccountHoverView`。
struct AccountHoverView: View {
    let title: String
    let sourceNote: String
    let planLabel: String?
    let accountEmail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "person.crop.circle")
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
            }

            if let accountEmail, !accountEmail.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "envelope")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                    Text(accountEmail)
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                }
            } else {
                Text("未拿到账号邮箱（首次刷新后会显示）")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            if let planLabel, !planLabel.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "rosette")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                    Text(planLabel)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            Text(sourceNote)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .frame(width: 240, alignment: .leading)
    }
}

/// Antigravity 卡片标题的 hover 详情。
struct AntigravityAccountHoverView: View {
    let planLabel: String?
    let accountEmail: String?

    var body: some View {
        AccountHoverView(
            title: "Google Antigravity 账号",
            sourceNote: "数据来源：本机 Antigravity IDE / agy CLI 的 language_server",
            planLabel: planLabel,
            accountEmail: accountEmail
        )
    }
}

/// ChatGPT (Codex) 卡片标题的 hover 详情。
struct ChatGPTAccountHoverView: View {
    let planLabel: String?
    let accountEmail: String?

    var body: some View {
        AccountHoverView(
            title: "ChatGPT / Codex 账号",
            sourceNote: "数据来源：~/.codex/auth.json",
            planLabel: planLabel,
            accountEmail: accountEmail
        )
    }
}
