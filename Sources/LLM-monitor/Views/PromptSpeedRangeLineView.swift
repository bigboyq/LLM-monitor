import SwiftUI

/// A compact min–max line. Model rows share one menu-wide numeric domain; when used
/// alone, the row's own endpoints provide the domain.
struct PromptSpeedRangeLineView: View {
    let statistics: PromptSpeedStatistics
    let scaleRange: ClosedRange<Double>?

    private var minimum: Double? { finiteNonnegative(statistics.minimum) }
    private var maximum: Double? { finiteNonnegative(statistics.maximum) }
    private var latest: Double? { finiteNonnegative(statistics.latest) }
    private var effectiveScale: ClosedRange<Double>? {
        scaleRange ?? minimum.flatMap { lower in maximum.map { lower...$0 } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let minimum, let maximum, statistics.validPromptCount > 0 {
                GeometryReader { geometry in
                    let width = max(geometry.size.width - 8, 1)
                    let xMin = x(for: minimum, width: width)
                    let xMax = x(for: maximum, width: width)
                    let xLatest = latest.map { x(for: $0, width: width) }

                    ZStack {
                        Rectangle()
                            .fill(Color.secondaryLabel.opacity(0.18))
                            .frame(width: width, height: 1)
                            .position(x: width / 2, y: 6)

                        Capsule()
                            .fill(Color.accentColor.opacity(0.78))
                            .frame(width: max(xMax - xMin, 1.5), height: 2)
                            .position(x: (xMin + xMax) / 2, y: 6)

                        Rectangle()
                            .fill(Color.secondaryLabel)
                            .frame(width: 1, height: 8)
                            .position(x: xMin, y: 6)
                        Rectangle()
                            .fill(Color.secondaryLabel)
                            .frame(width: 1, height: 8)
                            .position(x: xMax, y: 6)

                        if let xLatest {
                            RoundedRectangle(cornerRadius: 1)
                                .fill(Color.primaryLabel)
                                .frame(width: 6, height: 6)
                                .rotationEffect(.degrees(45))
                                .position(x: xLatest, y: 6)
                        }
                    }
                    .frame(width: width, height: 12)
                    .padding(.horizontal, 4)
                }
                .frame(height: 12)

                HStack(spacing: 4) {
                    Text("min \(Self.speedValue(minimum))")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("max \(Self.speedValue(maximum))")
                        .frame(maxWidth: .infinity, alignment: .center)
                    Text("最近 \(Self.speedValue(latest))")
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .font(MenuTypography.hint.monospacedDigit())
                .foregroundStyle(Color.secondaryLabel)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .help("范围线端点为 min/max，◆标记最近一次 Prompt。该 Prompt 缺少时长时不画标记并显示 —。速度单位 tok/s。有效 Prompt / 今日已记录 Prompt：\(statistics.validPromptCount)/\(statistics.totalPromptCount)。")
            } else {
                Text("速度范围 —")
                    .font(MenuTypography.hint)
                    .foregroundStyle(Color.secondaryLabel)
                    .help("没有可用的完整 Prompt 速度样本；速度单位 tok/s。有效 Prompt / 今日已记录 Prompt：\(statistics.validPromptCount)/\(statistics.totalPromptCount)。")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    var accessibilityLabel: String {
        guard let minimum, let maximum, statistics.validPromptCount > 0 else {
            return "速度范围无可用数据，单位 tok/s；有效 Prompt \(statistics.validPromptCount)/\(statistics.totalPromptCount)"
        }
        return "速度范围，单位 tok/s：最小 \(Self.speedValue(minimum))，最大 \(Self.speedValue(maximum))，最近 Prompt \(Self.speedValue(latest))；有效 Prompt \(statistics.validPromptCount)/\(statistics.totalPromptCount)"
    }

    static func speedText(_ value: Double?) -> String {
        "\(speedValue(value)) tok/s"
    }

    static func speedValue(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        return QuotaWindowUsageSection.speedText(value)
    }

    private func finiteNonnegative(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    private func x(for value: Double, width: CGFloat) -> CGFloat {
        PromptSpeedRangeGeometry.x(for: value, scaleRange: effectiveScale, width: width)
    }
}

/// Maps a value into the same linear domain for every local model row.
enum PromptSpeedRangeGeometry {
    static func x(for value: Double, scaleRange: ClosedRange<Double>?, width: CGFloat) -> CGFloat {
        let availableWidth = max(width.isFinite ? width : 0, 0)
        guard value.isFinite,
              let scaleRange,
              scaleRange.lowerBound.isFinite,
              scaleRange.upperBound.isFinite else {
            return availableWidth / 2
        }
        let span = scaleRange.upperBound - scaleRange.lowerBound
        guard span > 0 else { return availableWidth / 2 }
        let fraction = min(max((value - scaleRange.lowerBound) / span, 0), 1)
        return CGFloat(fraction) * availableWidth
    }
}
