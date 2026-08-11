import SwiftUI

/// DeepSeek 卡片标题的 hover 详情：充值金与赠金明细。
struct DeepseekAccountHoverView: View {
    let planLabel: String?
    /// R7: 余额明细由结构化字段本地格式化。
    let balanceDetail: DeepseekBalanceDetail?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "creditcard.fill")
                    .foregroundStyle(.secondary)
                Text("DeepSeek API 账户余额")
                    .font(.system(size: 12, weight: .semibold))
            }

            if let planLabel, !planLabel.isEmpty {
                HStack(spacing: 4) {
                    Text("总可用余额:")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Text(planLabel)
                        .font(.system(size: 12, weight: .bold).monospacedDigit())
                        .foregroundStyle(.primary)
                }
            }

            if let detail = balanceDetail {
                let symbol = detail.symbol
                HStack(spacing: 10) {
                    HStack(spacing: 4) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tertiary)
                        Text("充值: \(symbol)\(String(format: "%.2f", detail.toppedUp))")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Text("赠金: \(symbol)\(String(format: "%.2f", detail.granted))")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            Text("数据来源：https://api.deepseek.com/user/balance")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .frame(width: 240, alignment: .leading)
    }
}
