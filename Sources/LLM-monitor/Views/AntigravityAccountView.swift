import SwiftUI

/// Antigravity 卡片标题的 hover 详情：登录账号 + 套餐名。
/// 邮箱为空时只显示套餐名（与 ChatGPT 的"hover 显示用量"对称，
/// 缺失字段不显示而不是显示占位符）。
struct AntigravityAccountHoverView: View {
    let planLabel: String?
    let accountEmail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "person.crop.circle")
                    .foregroundStyle(.secondary)
                Text("Google Antigravity 账号")
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

            Text("数据来源：本机 Antigravity IDE / agy CLI 的 language_server")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .frame(width: 240, alignment: .leading)
    }
}

/// ChatGPT (Codex) 卡片标题的 hover 详情：登录账号 + 套餐名。
struct ChatGPTAccountHoverView: View {
    let planLabel: String?
    let accountEmail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "person.crop.circle")
                    .foregroundStyle(.secondary)
                Text("ChatGPT / Codex 账号")
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

            Text("数据来源：~/.codex/auth.json")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .frame(width: 240, alignment: .leading)
    }
}
