import SwiftUI

/// Prompt 速度分布的紧凑范围线。scaleMaximum 由当前菜单的全部本地行共享，
/// 使展开后的模型间能直接比较；无效 / 非有限读数不会进入坐标映射。
struct PromptSpeedRangeLineView: View {
    let statistics: PromptSpeedStatistics
    let scaleMaximum: Double?

    private var minimum: Double? { finitePositiveOrZero(statistics.minimum) }
    private var maximum: Double? { finitePositiveOrZero(statistics.maximum) }
    private var p50: Double? { finitePositiveOrZero(statistics.p50) }
    private var latest: Double? { finitePositiveOrZero(statistics.latest) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let minimum, let maximum, statistics.validPromptCount > 0 {
                GeometryReader { geometry in
                    let width = max(geometry.size.width - 12, 1)
                    let xMin = x(for: minimum, width: width)
                    let xMax = x(for: maximum, width: width)
                    let xP50 = p50.map { x(for: $0, width: width) }
                    let xLatest = latest.map { x(for: $0, width: width) }
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.10)).frame(height: 2)
                        Capsule()
                            .fill(Color.accentColor.opacity(0.75))
                            .frame(width: max(xMax - xMin, 2), height: 3)
                            .offset(x: xMin)
                        Circle().stroke(Color.secondary, lineWidth: 1.2)
                            .frame(width: 6, height: 6).position(x: xMin, y: 7)
                        Circle().stroke(Color.secondary, lineWidth: 1.2)
                            .frame(width: 6, height: 6).position(x: xMax, y: 13)
                        if let xP50 {
                            Circle().fill(Color.accentColor)
                                .frame(width: 7, height: 7).position(x: xP50, y: 6)
                        }
                        if let xLatest {
                            RoundedRectangle(cornerRadius: 1)
                                .fill(Color.primaryLabel)
                                .frame(width: 3, height: 8).position(x: xLatest, y: 14)
                        }
                    }
                    .frame(width: width, height: 20)
                    .padding(.horizontal, 6)
                }
                .frame(height: 20)
                HStack(spacing: 8) {
                    Text("min \(Self.speedValue(minimum))")
                    Text("P50 \(Self.speedValue(p50))")
                    Text("max \(Self.speedValue(maximum))")
                    Text("最近 \(Self.speedValue(latest)) tok/s")
                    Text("Prompt \(statistics.validPromptCount)/\(statistics.totalPromptCount)")
                        .help("有效 Prompt / 今日已记录 Prompt；任一调用缺失有效时长时，整个 Prompt 不参与速度分布。最近 Prompt 缺失时长显示 —，不回填旧值。")
                    Spacer(minLength: 0)
                }
                .font(MenuTypography.hint)
                .foregroundStyle(Color.secondaryLabel)
                .monospacedDigit()
                .lineLimit(1)
                .help("按 Prompt 统计的速度范围；圆点为 P50，竖线为最近一次 Prompt")
            } else {
                Text("速度范围 —（有效 Prompt \(statistics.validPromptCount)/\(statistics.totalPromptCount)）")
                    .font(MenuTypography.hint)
                    .foregroundStyle(Color.secondaryLabel)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("速度范围：最小 \(Self.speedText(minimum))，P50 \(Self.speedText(p50))，最大 \(Self.speedText(maximum))，最近 Prompt \(Self.speedText(latest))，有效 Prompt \(statistics.validPromptCount)/\(statistics.totalPromptCount)")
    }

    static func speedText(_ value: Double?) -> String {
        "\(speedValue(value)) tok/s"
    }

    private static func speedValue(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        return QuotaWindowUsageSection.speedText(value)
    }

    private func finitePositiveOrZero(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    private func x(for value: Double, width: CGFloat) -> CGFloat {
        let bound = (scaleMaximum.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? maximum ?? 0)
        guard bound > 0 else { return width / 2 }
        return min(max(CGFloat(value / bound) * width, 0), width)
    }
}
